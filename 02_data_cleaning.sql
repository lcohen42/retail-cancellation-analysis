/* ======================================================================== *
   SCRIPT   : 02_data_cleaning.sql
   PURPOSE  : Build the cleaned, flagged table and the default analysis view.
              Records are FLAGGED, not deleted, so nothing is lost. The view
              applies the default filters for analysis.
   DATASET  : Online Retail II (UCI dataset 502)
   DEPENDS  : 00_create_table.sql, 01_data_validation.sql (decisions carried in)
   OUTPUTS  : online_retail_clean (table), online_retail_clean_filtered (view)
   ======================================================================== */
   
-- ===========================================================================
-- DIAGNOSTIC PRE-CHECK 1
-- ===========================================================================

-- Confirming whitespace in description field values exists before bothering with TRIM.

SELECT
    COUNT(*) AS total_records,
    COUNT_IF(description <> TRIM(description)) AS description_untrimmed
FROM online_retail;

-- Results: 4,105 out of 1,067,371 rows have whitespace, so TRIM(description)
-- is justified.


-- ===========================================================================
-- DIAGNOSTIC PRE-CHECK 2
-- ===========================================================================

-- Confirming if UPPER(stock_code) would merge any distinct products.

SELECT UPPER(stock_code) AS upper_code,
       COUNT(DISTINCT stock_code) AS code_variants,
       COUNT(DISTINCT description) AS desc_variants,
       LISTAGG(DISTINCT stock_code, ' | ') AS codes,
       LISTAGG(DISTINCT description, ' | ') AS descriptions
FROM online_retail
GROUP BY UPPER(stock_code)
HAVING COUNT(DISTINCT stock_code) > 1
ORDER BY desc_variants DESC;

-- Results: 173 codes have both an uppercase and a lowercase form. Of those, 106 have
-- a single shared description (desc_variants = 1) making them unambiguously one product. The
-- other 67 show >1 description, BUT this query pools descriptions across variants, so
-- it can't tell which description belongs to which case. That variance is freetext
-- drift + stock notes + blanks, not necessarily distinct products. Inconclusive for
-- those 67 on its own. They need a closer look in pre-check 2b.


-- ---------------------------------------------------------------------------
-- DIAGNOSTIC PRE-CHECK 2B
-- ---------------------------------------------------------------------------

-- Confirming the 67 inconclusive collisions. Groups by the raw (case-sensitive) stock_code
-- so each variant's descriptions land on their own rows, ranked by frequency, making the
-- case-to-product mapping visible.

SELECT stock_code, description, COUNT(*) AS n
FROM online_retail
WHERE UPPER(stock_code) IN (
    SELECT UPPER(stock_code)
    FROM online_retail
    GROUP BY UPPER(stock_code)
    HAVING COUNT(DISTINCT stock_code) > 1
)
GROUP BY stock_code, description
ORDER BY UPPER(stock_code), stock_code, n DESC;

-- Results: 573 rows. In every collision, each variant's dominant description matches
-- its case-partner's (e.g. 85123A / 85123a both WHITE HANGING HEART T-LIGHT HOLDER).
-- The lowercase form is usually the minority, though in some codes (e.g. 84873a,
-- 84030c, 72801d) it carries comparable or greater volume. This means the split says nothing
-- about which is "real," and both are the same product either way. No case-pair maps
-- to two distinct products.
-- Conclusion: UPPER(stock_code) is safe across all 173 collisions.


-- ===========================================================================
-- DIAGNOSTIC PRE-CHECK 3
-- ===========================================================================


-- Confirm C and A are the ONLY invoice prefixes, so ELSE = sale is safe.

SELECT DISTINCT LEFT(invoice, 1) AS prefix
FROM online_retail
ORDER BY prefix;

-- Results: Values for prefix are 4, 5, C, and A. This confirms C and A are the only
-- letter prefixes.
-- Now to double check the patterns between letters and digits in invoice values
-- to make sure there are no mid-string letters. This code turns digits to "D" and
-- letters to "L" like in Section 14 from 01.data_validation.:

SELECT
    REGEXP_REPLACE(REGEXP_REPLACE(invoice, '[A-Za-z]', 'L'), '[0-9]', 'D') AS code_pattern,
    COUNT(DISTINCT invoice) AS distinct_codes,
    COUNT(*) AS total_records
FROM online_retail
GROUP BY code_pattern
ORDER BY distinct_codes DESC;

-- Results: The pattern check returned ONLY DDDDDD, LDDDDDD, so no mid-string letters,
-- no third letter, and at most one letter always followed by 6 digits.
-- So the ELSE branch = clean numeric = genuine sale. No hidden 4th category.
-- SCOPE: classifies by prefix ONLY. Business-non-sales (all-postage, zero-price,
-- null-customer) still land on 'sale' here and are caught by separate flags.



-- ===========================================================================
-- BUILDING THE TABLE
-- ===========================================================================
--
--
-- ---------------------------------------------------------------------------
-- 1. record_type Field
-- ---------------------------------------------------------------------------

-- The first field I need to create with the cleaned table is the record_type field which will 
-- categorize the records by invoice value prefix as cancelations, adjustments, or sales. Since
-- sales lack an invoice prefix, they'll be the ELSE.

/* CASE
    WHEN LEFT(invoice, 1) = 'C' THEN 'cancelation'
    WHEN LEFT(invoice, 1) = 'A' THEN 'adjustment'
    ELSE 'sale'
END AS record_type, */

-- ---------------------------------------------------------------------------
-- 2. price = 0 and customer_id IS NULL Flags
-- ---------------------------------------------------------------------------

-- Both of the conditions were chosen to help separate genuine sales from records that may not be.
-- Flagging them instead of outright filtering them at table creation allows the records to be 
-- looked at later if the decision is made that they somehow still have value. This code creates 
-- them as boolean fields with TRUE/FALSE values depending on whether the record meets the condition. 

/* price = 0 AS is_zero_price,
customer_id IS NULL AS is_null_customer, */

-- ---------------------------------------------------------------------------
-- 3. Non-products vs Products
-- ---------------------------------------------------------------------------

-- In 01_data_validation, I identified that the majority of stock_code values follow a pattern of 5
-- digits with up to two optional letter characters. An evaluation of outlying values showed that
-- some stock_codes that failed to meet the pattern could still be genuine products (e.g. DCGS*, SP1002, PADS).
-- To compensate, this field will flag the identified non-product stock_codes. The records can then be
-- filtered on this field instead of the 5 digit with up to two letter characters pattern which risks
-- filtering out potentially genuine sales records. The kept products fall into the ELSE. The code
-- uses CASE logic to create another field of boolean values.

/* CASE
    WHEN stock_code IN (
        'DOT', 'POST', 'C2', 'C3',            -- postage / carriage
        'AMAZONFEE', 'BANK CHARGES', 'CRUK',  -- fees / commission
        'B', 'D', 'M', 'ADJUST', 'ADJUST2',   -- adjustments (bad debt, discount, manual)
        'S'                                   -- samples
    ) THEN TRUE
    WHEN stock_code LIKE 'GIFT%' THEN TRUE   -- gift vouchers
    WHEN stock_code LIKE 'TEST%' THEN TRUE   -- test data
    ELSE FALSE   -- real product, incl. DCGS*, SP1002, PADS
END AS is_non_product, */
-- ---------------------------------------------------------------------------
-- 4. Surrogate Key
-- ---------------------------------------------------------------------------

-- In 01_data_validation, I discussed how this dataset doesn't have a unique key column,
-- a field with values that can be used to call on specific individual records. row_key fills
-- that gap. Its purpose is the Q3 self-join, where I match cancelations back to their original
-- sales. That join matches on natural columns (customer_id, stock_code, quantity sign-flipped,
-- sale_date <= cancelation_date), NOT on row_key. A cancelation and its original are different
-- rows with different keys. row_key does two things the natural columns can't:
--   (1) When one cancelation has several candidate originals, row_key is the deterministic
--       handle to pick exactly one (partition by the cancelation's key, order by sale_date,
--       tie-break on the sale's key).
--   (2) Retained duplicate rows are byte-identical, so the natural columns can't tell two
--       duplicates apart. row_key is the only thing that can.
-- Point (2) is why it's ROW_NUMBER() and not HASH/MD5: identical rows hash to the same value
-- (useless here), but ROW_NUMBER assigns distinct values even to identical rows. The key is
-- materialized at build time (frozen, doesn't recompute on query) and never leaves the table,
-- so its values only need to be unique within a build. The ORDER BY is for deterministic
-- assignment, not meaning, so don't read signal into the ordering.

/* ROW_NUMBER() OVER(ORDER BY invoice, stock_code, invoice_date) AS row_key */

-- ===========================================================================
-- ASSEMBLING THE TABLE
-- ===========================================================================
--
-- Now all of the pieces of code are put together in a single query. Since I also want to normalize
-- certain field values, I've split the query into a CTE that cleans up the data and a main query
-- that adds the filter columns and the surrogate key. 


CREATE OR REPLACE TABLE online_retail_clean AS

WITH normalize AS (
    SELECT
        invoice,
        UPPER(stock_code) AS stock_code,
        TRIM(description) AS description,
        quantity,
        invoice_date,
        price,
        customer_id,
        country,
        LEFT(invoice, 1) AS invoice_prefix
    FROM online_retail  
)

SELECT
    ROW_NUMBER() OVER(ORDER BY invoice, stock_code, invoice_date) AS row_key,
    invoice,
    stock_code,
    description,
    quantity,
    invoice_date,
    price,
    customer_id,
    country,
    CASE
       WHEN invoice_prefix = 'C' THEN 'cancelation'
       WHEN invoice_prefix = 'A' THEN 'adjustment'
       ELSE 'sale'
    END AS record_type,
    price = 0 AS is_zero_price,
    customer_id IS NULL AS is_null_customer,
    CASE
       WHEN stock_code IN (
        'DOT', 'POST', 'C2', 'C3',            -- postage / carriage
        'AMAZONFEE', 'BANK CHARGES', 'CRUK',  -- fees / commission
        'B', 'D', 'M', 'ADJUST', 'ADJUST2',   -- adjustments (bad debt, discount, manual)
        'S'                                   -- samples
       ) THEN TRUE
       WHEN stock_code LIKE 'GIFT%' THEN TRUE   -- gift vouchers
       WHEN stock_code LIKE 'TEST%' THEN TRUE   -- test data
       ELSE FALSE   -- real product, incl. DCGS*, SP1002, PADS
    END AS is_non_product
FROM normalize;

--Results: Table shown as successfully created.


-- ===========================================================================
-- POST-BUILD SANITY CHECKS
-- ===========================================================================

-- Simple checks to make sure that the table was created correctly and that row counts
-- match the original table. They should all return zero rows if everything went right.

-- ---------------------------------------------------------------------------
-- row_key Uniqueness Test
-- ---------------------------------------------------------------------------

-- The correct response should be zero rows

SELECT row_key, COUNT(*)
FROM online_retail_clean
GROUP BY row_key
HAVING COUNT(*) > 1;

-- Results: Zero rows.

-- ---------------------------------------------------------------------------
-- row-count Parity (flag-based, nothing deleted) Test
-- ---------------------------------------------------------------------------

-- The correct response should be zero rows

SELECT 'row count mismatch' AS check_failed
WHERE (SELECT COUNT(*) FROM online_retail_clean)
   <> (SELECT COUNT(*) FROM online_retail);
   
-- Results: Zero rows.   

-- ---------------------------------------------------------------------------
-- record_type parity source vs clean Test
-- ---------------------------------------------------------------------------

-- The correct response should be zero rows
WITH src AS (
    SELECT CASE WHEN LEFT(invoice,1) = 'C' THEN 'cancelation'
                WHEN LEFT(invoice,1) = 'A' THEN 'adjustment'
                ELSE 'sale' END AS record_type, COUNT(*) AS n
    FROM online_retail GROUP BY 1
),
cln AS (
    SELECT record_type, COUNT(*) AS n
    FROM online_retail_clean GROUP BY 1
)
SELECT
    COALESCE(src.record_type, cln.record_type) AS record_type,
    src.n AS source_n,
    cln.n AS clean_n
FROM src
FULL OUTER JOIN cln
    ON src.record_type = cln.record_type
WHERE src.n IS DISTINCT FROM cln.n;

-- Results: Zero rows.

-- All three queries return zero rows, so everything checks out. This table represents the
-- full original dataset with the updated columns that can be used to flag records for sorting
-- and filtering during analysis. No rows are deleted in case I decide I may need them later.



-- ===========================================================================
-- CREATING A FILTERED VIEW
-- ===========================================================================

-- This code creates a filtered view of the clean table to use in analysis. The query filters
-- out the adjustment records since I'm focusing on sales and cancelations as well as getting
-- rid of everything that was identified as a non-product.
-- NOTE: Both sales and cancelations are present in this view. Since quantity is negative for
-- cancelations, SUM(quantity * price) returns NET. Gross needs an explicit record_type = 'sale'
-- slice.
-- Zero-price junk (price = 0 AND customer_id IS NULL, per 01 Section 12.2) is flagged on the
-- clean table but NOT filtered here. It carries zero value, so it cannot affect value-based
-- results, and customer-level queries exclude null customers directly. It does sit in the
-- sale-side UNIT totals, so unit-based figures (Q1 units) include it and should be read as
-- approximate.


CREATE OR REPLACE VIEW online_retail_clean_filtered AS

SELECT *
FROM online_retail_clean
WHERE is_non_product = FALSE
  AND record_type <> 'adjustment';

-- Results show view was successfully created

SELECT 
    record_type, 
    COUNT(*)
FROM online_retail_clean_filtered
GROUP BY record_type;

-- A quick check shows that only sale and cancelation records are present, and that
-- both have had non-product records filtered out.


-- ===========================================================================
-- CLEANING PHASE COMPLETE
-- ===========================================================================
--
-- online_retail_clean (table): full dataset, flag-based, nothing deleted.
-- online_retail_clean_filtered (view): default analysis population,
--   non-products and adjustments dropped, both sale and cancelation kept.
-- All three post-build assertions return zero rows on rebuild.
--
-- Analysis phase (Q1-Q4) lives in the next file. Q3 uses the row_key
-- self-join. Reminder: the view carries both sales and cancelations,
-- so SUM(quantity * price) is NET, gross needs record_type = 'sale'.
