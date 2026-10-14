/* ======================================================================== *
   SCRIPT   : 01_data_validation.sql
   PURPOSE  : Profile and validate the loaded Online Retail II data before any
              cleaning, and record every deferred cleaning/analysis decision.
   DATASET  : Online Retail II (UCI dataset 502)
   DEPENDS  : 00_create_table.sql (table online_retail must already be loaded)
   OUTPUTS  : Deferred-decision manifest at end of file
              (feeds 02_data_cleaning.sql and 03_data_analysis.sql).
   ======================================================================== */

-- ===========================================================================
-- SECTION 1 : DATA TYPES
-- ===========================================================================

-- First to check that the data types loaded correctly.

DESCRIBE TABLE online_retail;

-- Results:
-- INVOICE	VARCHAR(20)
-- STOCK_CODE	VARCHAR(20)
-- DESCRIPTION	VARCHAR(500)
-- QUANTITY	NUMBER(10,0)
-- INVOICE_DATE	TIMESTAMP_NTZ(9)
-- PRICE	NUMBER(10,2)
-- CUSTOMER_ID	NUMBER(10,0)
-- COUNTRY	VARCHAR(100)

-- Everything looks good. The price data type ensures no drift for calculations.

-- ===========================================================================
-- SECTION 2 : NULL CHECK
-- ===========================================================================

-- Count if there are any NULLs or blank entries (empty or whitespace only) in any of 
-- the fields that may cause issues with calculations later. IS NULL looks for NULL values
-- while TRIM(field_name) = '' checks VARCHAR type fields for values with only whitespace.

SELECT
    COUNT(*) AS total_rows,
    COUNT_IF(invoice IS NULL OR TRIM(invoice) = '') AS invoice_nulls,
    COUNT_IF(stock_code IS NULL OR TRIM(stock_code) = '') AS stock_code_nulls,
    COUNT_IF(description IS NULL OR TRIM(description) = '') AS description_nulls,
    COUNT_IF(quantity IS NULL) AS quantity_nulls,
    COUNT_IF(invoice_date IS NULL) AS invoice_date_nulls,
    COUNT_IF(price IS NULL) AS price_nulls,
    COUNT_IF(customer_id IS NULL) AS customer_id_nulls,
    COUNT_IF(country IS NULL OR TRIM(country) = '') AS country_nulls
FROM online_retail;

-- Results: 1,067,371 total records
-- Zero nulls for invoice, stock_code, quantity, invoice_date, price, and country.
-- 4,382 NULL values in description field and 243,007 NULLS in customer_id field.
-- Every VARCHAR field returned 0 on the combined (IS NULL OR TRIM = '') predicate, so
-- blank-but-not-null strings don't exist in this table and IS NULL on its own is enough
-- from here on.

-- Looking further into the NULL values to see if they are real product entries. This
-- will check the range for price and if the entries have NULLs for customer_id.

SELECT
    COUNT(*) AS total_rows,
    MIN(price) AS min_price,
    MAX(price) AS max_price,
    COUNT_IF(customer_id IS NULL) AS customer_id_nulls
FROM online_retail
WHERE description IS NULL;

-- Results:
-- Total record count where description is blank (4,382), agreeing with result from the previous
-- code, the price is always 0, and no customer_id attached. This indicates a single junk/artifact
-- population, not three separate problems.
-- Cleaning decision deferred: price = 0 rule (02_data_cleaning.sql)


-- ===========================================================================
-- SECTION 3 : RECORD TYPE TAXONOMY
-- ===========================================================================

-- Now to look at the rest of the cases of missing customer_id by what 
-- type of record they are. The letter prefix before the invoice number should indicate type of 
-- record, so I will sort by that. I will then calculate what % of those type of records 
-- have missing customer_id to get a sense of the size of the issue.
-- First, to make sure there are no whitespaces in invoice.

SELECT
    COUNT_IF(invoice <> TRIM(invoice)) AS invoice_untrimmed,
    COUNT_IF(stock_code <> TRIM(stock_code)) AS stock_code_untrimmed,
    COUNT_IF(country <> TRIM(country)) AS country_untrimmed,
    COUNT_IF(LEFT(invoice, 1) <> UPPER(LEFT(invoice, 1))) AS invoice_lowercase_prefix
FROM online_retail;

-- Results: All 0, no leading/trailing whitespace in invoice, stock_code or country, and no
-- lowercase invoice prefixes. Worth checking given m/M shows up in stock_code. Since there
-- are no lowercase prefixes, LIKE 'C%' would do, but keeping ILIKE as a safety net.

SELECT
    CASE
      WHEN invoice ILIKE 'C%' THEN 'cancelation'
      WHEN invoice ILIKE 'A%' THEN 'adjustment'
      ELSE 'sale'
    END AS record_type,
    COUNT(*) AS total_rows,
    COUNT_IF(customer_id IS NULL) AS customer_id_nulls,
    ROUND(100 * COUNT_IF(customer_id IS NULL) / COUNT(*), 1) AS pct_null,
    SUM(quantity * price) AS total_revenue
FROM online_retail
GROUP BY record_type
ORDER BY total_rows DESC;

-- Results: 23% of sales records have no customer_id. Only 3.8% of cancelations lack
-- customer_id. Since customer_id is needed to match records, that means at least 3.8% of 
-- cancelations can't be matched to their sale record. 
-- Revenue by record_type shown here as profiling only. Pre-dedupe, pre-price-rule,
-- adjustments still in. These are indicative, not final. Note: cancelation value
-- is -1,526,667.86 against gross sales of 20,961,532.49 = 7.3%, vs 1.83% of rows.
-- Cancelations are ~4x more material by value than by count. Q1 computes this properly
-- on the clean layer with a sales-only denominator.

-- Looking closer at Adjustments since 100% are missing customer_ids.

SELECT *
FROM online_retail
WHERE invoice ILIKE 'A%';

-- Results: 6 records, all description = 'Adjust bad debt', stock_code = 'B', country = United Kingdom.
-- Quantity always 1 with a large amount sitting in price (from -53K to 11K). Shaped like ledger 
-- entry, not a product line.
-- quantity * price across the 6 nets -147,614.08, so they are NOT revenue-neutral. Excluding
-- them is a material change, which is the reason to exclude rather than a reason not to.
-- (invoice values A563185/86/87 on 2011-08-12 are a +/- correction sequence. Noted for Section 
-- 10 Numeric Sanity Check.)

-- Checking whether stock_code 'B' turns up anywhere outside these 6.

SELECT *
FROM online_retail
WHERE stock_code ILIKE 'B';

-- Results: Confirm stock_code "B" is only used in these particular records, so removing adjustments
-- also clears 'B' off the non-product stock_code list without separate judgement call.
-- Cleaning decision deferred: exclude as ledger corrections (02_data_cleaning.sql)

-- ===========================================================================
-- SECTION 4 : ANONYMOUS REVENUE SHARE
-- ===========================================================================
-- 23% of sales rows having no customer_id doesn't tell me how big the problem is, because rows aren't
-- money. Those rows have to be dropped from any customer-level work (Q2), so I need the share of 
-- sales revenue that goes with them.
-- Filtering out cancelations and adjustments first so the denominator is sales revenue only.
-- SUM(SUM(...)) OVER () runs after the GROUP BY, so it totals the two groups and turns the number
-- into a share.

SELECT
    (customer_id IS NULL) AS is_anonymous,
    COUNT(*) AS total_rows,
    SUM(quantity * price) AS total_revenue,
    ROUND(
        100 * SUM(quantity * price) / SUM(SUM(quantity * price)) OVER (), 1
    ) AS pct_of_sales_revenue
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%'
GROUP BY is_anonymous;

-- Results: 
-- FALSE (records with customer_id): 805,620 rows, 17,743,429.16 GBP, or 84.6% of sales revenue
-- TRUE (records missing customer_id): 242,251 rows, 3,218,103.33 GBP, or 15.4% of sales revenue

-- This is the denominator behind the limitations line. Customer-level findings cover 84.6% of 
-- sales revenue, the other 15.4% is unattributable. Cancelations are ~96% attributable, so 
-- the gap is asymmetric. The cancelation side of Q2 is solid, the sales base it's measured    
-- against less so.


-- ===========================================================================
-- SECTION 5 : TEST KEY UNIQUENESS
-- ===========================================================================
-- The intended grain is one row per product per invoice, but there's nothing
-- enforcing it. Instead of testing candidates one at a time, I'll try testing a composite of
-- all eight columns. If the full set isn't unique, no subset can be, since rows identical on 
-- all eight are identical on any subset.

SELECT
    invoice,
    stock_code,
    description,
    quantity,
    invoice_date,
    price,
    customer_id,
    country,
    COUNT(*) AS match_count
FROM online_retail
GROUP BY ALL
HAVING COUNT(*) > 1
ORDER BY match_count DESC;

-- Results: ~32K groups, each occurring 2 to 20 times. No candidate key holds in this extract.
-- Uniqueness was asserted by the source system, not enforced by the data. The source almost
-- certainly keys lines as (invoice, line_number); that column isn't in the export.
-- Q3 consequence: no unique line identifier means a cancelation can fan out across several
-- candidate sale rows on the join.
-- Cleaning decision deferred: surrogate key on clean layer (02_data_cleaning.sql)

-- Note: Top groups are worth reading: invoice 555524 has 20x PINK REGENCY TEACUP and 12x GREEN,
-- both qty 1 @ 2.95, same customer, same minute. Different multipliers on the same invoice,
-- so this isn't a load repeat. A pipeline doubling would hit every line equally. Looks like
-- per-unit scanning rather than keying a quantity. Feeds the duplicate decision in 7.


-- ===========================================================================
-- SECTION 6 : INVOICE_DATE GRAIN AND RESOLUTION
-- ===========================================================================
-- Checked because if invoice_date varied within an invoice, it might discriminate rows
-- the key test couldn't.

SELECT
    invoice,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT invoice_date) AS distinct_ts,
    MIN(invoice_date) AS first_ts,
    MAX(invoice_date) AS last_ts,
    DATEDIFF('second', MIN(invoice_date), MAX(invoice_date)) AS spread_seconds
FROM online_retail
GROUP BY invoice
HAVING COUNT(DISTINCT invoice_date) > 1
ORDER BY spread_seconds DESC;

-- Results: 83 invoices carry multiple timestamps (~0.16% of ~53K), all spreads of minutes, 82 of them
-- are sales. Not invoice-number reuse. Consistent with lines keyed across a minute boundary.


SELECT
    COUNT_IF(SECOND(invoice_date) <> 0) AS nonzero_seconds,
    COUNT(DISTINCT SECOND(invoice_date)) AS distinct_second_values
FROM online_retail;

-- Results: All 1,067,371 rows have seconds = 0 (one distinct value), meaning invoice_date is
-- minute-resolution. Explains the 83. Most orders are keyed inside one minute and collapse 
-- to one timestamp. Consequence: the timestamp can't separate a genuine repeat line from 
-- a double entry, since both land in the same minute. No impact on Q3, which matches at 
-- day granularity.


-- ===========================================================================
-- SECTION 7 : EXACT DUPLICATES
-- ===========================================================================
-- Now to measure the groups that the key test returned in terms of size and value.

SELECT
    COUNT(*) AS dupe_groups,
    SUM(n) AS rows_involved,
    SUM(n - 1) AS excess_rows,
    MAX(n) AS worst_group,
    SUM((n - 1) * quantity * price) AS excess_revenue
FROM (
    SELECT invoice,
           stock_code,
           description,
           quantity,
           invoice_date,
           price,
           customer_id,
           country,
           COUNT(*) AS n
    FROM online_retail
    GROUP BY ALL
    HAVING COUNT(*) > 1
);

-- Results: ~32K groups cover ~67K rows. If you assume that for each group you can keep one
-- and delete the rest, you would be deleting 34,335 excess rows = 3.2% of the table. The grouping
-- that includes the most records, or the Worst Group, has 20 records in it. Now to break
-- those results down by record_type.

SELECT
    CASE WHEN invoice ILIKE 'C%' THEN 'cancelation'
         WHEN invoice ILIKE 'A%' THEN 'adjustment'
         ELSE 'sale' END AS record_type,
    SUM(n - 1) AS excess_rows,
    SUM((n - 1) * quantity * price) AS excess_revenue
FROM (
    SELECT invoice, stock_code, description, quantity,
           invoice_date, price, customer_id, country,
           COUNT(*) AS n
    FROM online_retail
    GROUP BY ALL
    HAVING COUNT(*) > 1
)
GROUP BY record_type;

-- Results:
-- Sales: 33,945 excess rows, 496,334.12 GBP in value. Cancelations: 390 excess rows, -64,617.25 GBP (2.0% of
-- the 19,494 cancelation base). Deduping would move the cancelation share of gross sales revenue
-- from 7.3% to 7.1%. Immaterial to Q1 either way.
-- Cleaning decision deferred: retain duplicates (02_data_cleaning.sql). Multipliers vary within
-- invoice, so not a load artifact; deduping would delete units customers actually bought.
-- Cost: any true double-entries stay in the base and inflate line counts by an unknown amount.


-- ===========================================================================
-- SECTION 8 : DATE RANGE BOUNDARIES
-- ===========================================================================
-- Confirm the window is intact (no missing or empty
-- months) and characterize whether cancelations are a steady background rate or
-- episodic. Sales/cancelation counts and values side by side per month, plus a
-- cancelation rate on each basis. C/A predicate repeated here; to become the
-- materialized record_type column in 02_data_cleaning.sql.

SELECT *,
      ROUND((cancel_count / sales_count)*100,2) AS count_rate,
      ROUND(ABS(cancel_value)/sales_value *100, 2) AS value_rate
FROM (
    SELECT
        DATE_TRUNC('month', invoice_date) AS invoice_month,
        COUNT(*) AS total_count,
        COUNT_IF(invoice NOT ILIKE 'C%' AND invoice NOT ILIKE 'A%') AS sales_count,
        COUNT_IF(invoice ILIKE 'C%') AS cancel_count,
        SUM(CASE WHEN invoice NOT ILIKE 'C%' AND invoice NOT ILIKE 'A%'
                 THEN quantity * price END) AS sales_value,
        SUM(CASE WHEN invoice ILIKE 'C%'
                 THEN quantity * price END) AS cancel_value
    FROM online_retail
    GROUP BY invoice_month)
ORDER BY invoice_month;

-- Results: 25 months, Dec 2009 - Dec 2011, no gaps or empty months. Window is intact.
-- Dec 2011 is the smallest month (25,526 rows) because it's the partial right edge, not
-- a data problem.
-- count_rate is stable across all 25 months (1.29-2.86%, mostly ~1.8%), matching the
-- ~1.83% row-share headline. Cancelations are a steady proportion of activity by count.
-- value_rate is NOT stable: spikes in Dec 2010 (10.78), Jan 2011 (19.00), Dec 2011 (32.11).
-- Count barely moves while value lurches = the "row count is the wrong denominator" thesis
-- at monthly resolution. Dec 2011's spike is partly a partial-month edge artifact (thin
-- sales denominator, largest cancel_value at -205k).
-- Dec 2010-Jan 2011 value concentration is a Q2 question (few products or few customers?),
-- not investigated here.
-- analysis starting point deferred: Dec 2010-Jan 2011 cancelation value concentration (Q2)


-- ===========================================================================
-- SECTION 9 : PARTIAL CANCELATIONS TEST
-- ===========================================================================
-- Triage whether canceled quantities mirror sold quantities, or whether partials (bought 10, canceled 4)
-- break the mirror assumption Q3 matching depends on. Group to (customer_id, stock_code) pairs,
-- sum sale-type vs cancel-type units, classify by comparing the two sums.
-- Triage only -- the event-level version is the deferred Q3 self-join. C/A
-- predicate repeated here; becomes materialized record_type in 02_data_cleaning.sql.

WITH layer_one AS (
SELECT
	customer_id,
	stock_code,
	SUM(CASE WHEN invoice NOT ILIKE 'C%' AND invoice NOT ILIKE 'A%'
                 THEN quantity END) AS sales_quantity,
        SUM(CASE WHEN invoice ILIKE 'C%'
                 THEN ABS(quantity) END) AS cancel_quantity
FROM online_retail
WHERE customer_id IS NOT NULL
GROUP BY customer_id, stock_code
HAVING SUM(CASE WHEN invoice ILIKE 'C%'
                THEN ABS(quantity) END) > 0
),

bucketed AS (
SELECT
	CASE WHEN sales_quantity IS NULL THEN 'no sale'
	     WHEN cancel_quantity < sales_quantity THEN 'below'
             WHEN cancel_quantity = sales_quantity THEN 'whole'
	     ELSE 'above'      
        END AS match_bucket,
	COUNT(*) AS pair_count
FROM layer_one
GROUP BY match_bucket)

SELECT
    match_bucket,
    pair_count,
    ROUND(100.0 * pair_count / SUM(pair_count) OVER (), 1) AS pct
FROM bucketed
ORDER BY pair_count DESC;

-- Results: 15,493 cancelation-bearing pairs (null-customer_id excluded by construction,
-- so coverage is the ~96%-attributable population). below 10,889 (70.3%), whole
-- 3,047 (19.7%), no_sale 1,285 (8.3%), above 272 (1.8%).
-- below is a CEILING on partial prevalence, not a count: pair-lifetime grain
-- confounds a whole-cancelation of one repeat order (bought +10/+10/+10,
-- canceled -10 = ratio 0.33) with a true partial. The sum can't separate them.
-- So partials aren't ruled out and the ceiling is too high to dismiss, but the
-- probe bounds the worry (it does not confirm partials are common). Only the
-- event-level join resolves the real figure.
-- whole (19.7%) is the cleanly-matchable floor for Q3. above (1.8%) is
-- over-cancelation; flagged, not investigated, and its extreme tail is partly
-- a left-edge signature (canceled in-window, bought off-edge).
-- no_sale (1,285) = cancelation-bearing pairs with no in-window sale-type row
-- (sales_quantity IS NULL). Reuse this exact predicate in left-edge sizing so
-- the two Q3 floors reconcile rather than double-count.
-- analysis starting point deferred: partial-cancelation handling (Q3)



-- ===========================================================================
-- SECTION 10 : NUMERIC SANITY CHECK FOR SALES
-- ===========================================================================
-- This is to make sure there are no unexpected values
-- hiding in the data that might cause issues with calculations during analysis.
-- The two record types that analysis will focus on are sales and cancelations, so
-- I'll isolate those types to test price and quantity values. Starting with sales, 
-- I'll check for sign, magnitude, and zero/negative split.

SELECT
     COUNT(*) AS total_sales_rows,
     COUNT_IF(quantity <= 0) AS bad_quantity, 
     MIN(quantity) AS min_quantity,
     MAX(quantity) AS max_quantity,
     COUNT_IF(price < 0) AS neg_price,        
     COUNT_IF(price = 0) AS zero_price,
     MIN(price) AS min_price,
     MAX(price) AS max_price
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%';

-- Results: 3,457 sales records have non-positive quantities (the <= 0 check catches
-- zeros along with negatives). Minimum quantity was -9,600. Indicates possibly non-sales rows
-- not prefixed correctly, sitting in the sale bucket. Investigate next by grouping on 
-- stock_code/description. May require revising the record_type definition in Section 3.
-- Max quantity of 80,995 could be an entry error. Flagged for row-level inspection.
-- No negative prices, but 6,220 zero-price records. That's 1,838 beyond the 4,382 junk 
-- count from Section 2. Zero-price cleaning decision deferred to 02_data_cleaning.sql.
-- (Some of these zero-price rows resurface as large-quantity giants in Section 11.3.)



-- ===========================================================================
-- SECTION 11 : MAX QUANTITY FOLLOW UP
-- ===========================================================================
-- Max quantity 80,995 flagged as possible entry error.
-- Below code is to check whether it's a lone outlier or a population, and whether the large rows
-- carry the signature of real orders (real customer, real SKU, plausible price).

SELECT *
FROM online_retail
ORDER BY quantity DESC
LIMIT 50;

-- Results: not a lone outlier. The large quantities are a population, not a mistake.
-- Top rows carry real customer_id, real stock_code/description, price £0.10–£2.10.
-- Appear to be legitimate wholesale lines. A handful are price=0 / customer_id=NULL (shared
-- zero-price signature, see Section 2.Open cleaning question, not a quantity issue).
-- CONCLUSION: large quantities are real. NOT an error; no quantity-based drop.
-- If one lands big in Q2 concentration, that's a true business fact, not a distortion.
-- Keep/drop of the zero-price handful deferred to 02_data_cleaning.sql via the zero-price rule.
-- ^ PROVISIONAL conclusion! Rests on the top-50 eyeball. Verified below in 11.1–11.3,
-- which split the "suspect" flag and REVISED this: the giants are two classes, not one.



-- ---------------------------------------------------------------------------
-- 11.1  Giant verification (past the top-50 eyeball)
-- ---------------------------------------------------------------------------
-- Pull the large-quantity tail with the
-- disqualifying signature as a column. suspect = price=0 OR no customer_id (the
-- Section 2 junk signature minus NULL description). Reading it top-down: a giant row
-- flagged suspect is a possible fake giant that could distort Q2.

SELECT
    invoice,
    stock_code,
    quantity,
    price,
    customer_id,
    quantity * price AS line_value,
    (price = 0 OR customer_id IS NULL) AS suspect
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%'
ORDER BY quantity DESC
LIMIT 200;

-- Results: Suspect ran 80.5% false / 19.5% true across the top 200. NOT readable as-is. The OR
-- bundles two unlike things (anonymous-but-real priced lines vs zero-price junk). 19.5% is near
-- the customer_id-null base rate, so it could be all anonymous-real and zero junk. Split needed (11.2).


-- ---------------------------------------------------------------------------
-- 11.2  Split the suspect OR to read it
-- ---------------------------------------------------------------------------
-- Is the 19.5% anonymous-real (harmless) or zero-price (junk)?

SELECT
    COUNT(*) AS n_top,
    COUNT_IF(price = 0) AS n_zero_price,
    COUNT_IF(customer_id IS NULL) AS n_no_customer,
    COUNT_IF(price = 0 AND customer_id IS NULL) AS n_both,
    COUNT_IF(price > 0) AS n_priced
FROM (
    SELECT price, customer_id
    FROM online_retail
    WHERE invoice NOT ILIKE 'C%'
      AND invoice NOT ILIKE 'A%'
    ORDER BY quantity DESC
    LIMIT 200
     );

-- Results: n_zero_price = 37, n_no_customer = 38, near-total overlap. This rules out the 11.1 base-rate
-- reading (that the  19.5% was just anonymous-but-priced). The suspects are zero-price, not merely unattributed.
-- Same signature as Section 2. Whether they're real giants or just the tall end of a zero-price tail decides
-- the impact. Checked in 11.3.


-- ---------------------------------------------------------------------------
-- 11.3  Locate the 37 zero-price rows in the quantity ranking
-- ---------------------------------------------------------------------------
-- Giants, or modest rows that only
-- reached the top 200 because priced giants thin out fast?

SELECT
    quantity,
    price,
    customer_id,
    stock_code,
    description
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%'
  AND price = 0
ORDER BY quantity DESC
LIMIT 40;

-- Results: All in the THOUSANDS by quantity. Records are among the real giants, not below them.
-- REVISED Section 11 CONCLUSION (supersedes the provisional block above): the giant-quantity
-- population is TWO classes:
--   (a) real priced wholesale (real customer, £0.10–£2.10). Legit, keep;
--   (b) zero-price / no-customer / real-SKU rows at thousands of units. Section 2's signature
--       at large positive quantity.
-- Q2-VALUE impact: none. Zero price => zero line value => cannot distort a value-concentration
-- figure at any quantity. The thing this check protected is safe.
-- Q2-QUANTITY impact: real. A units-based cut would be distorted by these thousand-unit rows,
-- which are not genuine demand. Flag, don't drop (validation).
-- Likely the large-quantity end of the 6,220 zero-price sales from Section 10. Folds into the
-- single zero-price decision deferred to 02_data_cleaning.sql earlier, not a new population.



-- ===========================================================================
-- SECTION 12 : NON-POSITIVE ROWS FOLLOW UP
-- ===========================================================================
-- 3,457 non-positive-qty rows sitting in the "sale" bucket
-- (invoice not C/A, quantity <= 0). DISTINCT(stock_code)/DISTINCT(description) tried first
-- and discarded. DISTINCT drops frequency, and "do these cluster?" is a frequency question.
-- Grouped count is the right cut for "does the population concentrate in a few codes?"

SELECT
    stock_code,
    COUNT(*) AS n_rows,
    SUM(quantity) AS total_qty,
    MIN(quantity) AS min_qty,
    COUNT(customer_id) AS n_with_customer,
    COUNT_IF(price = 0) AS n_zero_price
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%'
  AND quantity <= 0
GROUP BY stock_code
ORDER BY n_rows DESC;

-- Results: Does NOT cluster by stock_code (top code 12 rows, then single digits, many codes).
-- But clusters perfectly by SIGNATURE. Every row price=0 and customer_id NULL, real SKUs,
-- real magnitudes (to -8,800). This is an inventory write-off population. A third record
-- type distinct from C (customer cancelation, priced) and A (ledger adjustment, stock_code "B").
-- Rules OUT the mis-prefixed-cancelation reading. A reversal would mirror its original's
-- price/customer and these carry neither, so they reverse nothing (incl. the Section 11 giants).


-- ---------------------------------------------------------------------------
-- 12.1  Confirmation
-- ---------------------------------------------------------------------------
-- Top-14 was uniformly price=0, but can't prove all 3,457 are.
-- Could impact later decisions: any price>0 negative would be a real mis-prefixed cancelation (Q3-
-- relevant), not a write-off, but only if they ALL follow the pattern. Below code collapses the whole 
-- population to one row to check homogeneity.

SELECT
    COUNT(*) AS n_rows,
    COUNT_IF(price = 0) AS n_zero_price,
    COUNT_IF(price > 0) AS n_positive_price,
    COUNT(customer_id)  AS n_with_customer,
    COUNT(DISTINCT stock_code) AS n_distinct_codes,
    MIN(quantity) AS min_qty
FROM online_retail
WHERE invoice NOT ILIKE 'C%'
  AND invoice NOT ILIKE 'A%'
  AND quantity <= 0;
  
-- Results: n_positive_price = 0 and n_with_customer = 0. Population is HOMOGENEOUS.
-- All zero-price, all unattributed. No priced negatives hiding in the tail.
-- CONCLUSION: mis-prefixed-cancelation hypothesis closed by count, not eyeball.
-- Section 3 taxonomy note: "else = sale" is contaminated by zero-price/unattributed negative-qty
-- write-offs. These are the Section 2 signature at negative quantity; 11.3 found the same
-- signature at large positive quantity. Sign is not part of the signature. The clean "sale"
-- guard must key on the price=0/no-customer SIGNATURE itself, unrestricted by sign, not on a
-- stock_code list. Transform deferred to 02_data_cleaning.sql.
-- OPEN CLEANING QUESTION (02): this population + Section 2 junk + Section 10 zero-price sales
-- + Section 11.3 positive zero-price giants all share price=0. Resolve as ONE zero-price
-- decision, not four overlapping drop-rules (double-count risk). 


-- ---------------------------------------------------------------------------
-- 12.2  Zero-price rule
-- ---------------------------------------------------------------------------
-- Pinning the exact form. Sections 2, 10, and 12 established the
-- zero-price population (6,220 rows) and its junk sub-populations (4,382 null-description,
-- 3,457 non-positive-quantity), all customer_id-null. What none of them tested is whether
-- price = 0 ALONE is sufficient for junk, or whether the customer_id-null half is load-bearing.
-- If every zero-price row is also customer-null, the two are equivalent and one condition
-- suffices. If any zero-price row carries a customer_id, they diverge and the rule needs both.
-- This checks the full zero-price set for attached customers.

SELECT
    CASE WHEN invoice ILIKE 'C%' THEN 'cancelation'
         WHEN invoice ILIKE 'A%' THEN 'adjustment'
         ELSE 'sale' END          AS record_type,
    COUNT(*)                        AS n,
    COUNT_IF(description IS NULL)    AS null_desc,
    COUNT_IF(quantity <= 0)         AS nonpos_qty,
    COUNT(DISTINCT stock_code)      AS distinct_codes,
    MIN(quantity)                   AS min_qty,
    MAX(quantity)                   AS max_qty
FROM online_retail
WHERE price = 0
  AND customer_id IS NOT NULL
GROUP BY record_type;

-- Results: 89 zero-price rows carry a customer_id, and all 89 are sales. None are
-- cancelations or adjustments, none have a null description, none have a non-positive
-- quantity. They span 62 stock_codes with quantities from 1 to 12,540. These are
-- legitimate zero-price product lines (real customer, real SKU, real quantity).
-- Free or promotional items, NOT artifacts.
-- So price = 0 alone is NOT the junk rule. It would wrongly delete these 89
-- real sales. The customer_id-null condition is load-bearing. Junk/artifact records are
-- price = 0 AND customer_id IS NULL. This is the single zero-price decision deferred
-- across Sections 2, 10, 11.3, and 12 now fixed in form. The 89 are retained because 
-- they FAIL this junk condition (customer attached). The rule keeps them on its own, 
-- no special handling. They contribute zero line value (price = 0) so they cannot affect 
-- value analysis, but they are real demand, so a units-based cut should account for them.
-- Note this is the opposite side of the drop line from the Section 11.3 zero-price giants,
-- which are no-customer and ARE dropped by this rule; the only thing the two share is 
-- zero value + relevance to a units-based cut.


-- ===========================================================================
-- SECTION 13 : NUMERIC SANITY FOR CANCELATIONS
-- ===========================================================================
-- Mirror of Section 10, sign expectation for quantity is flipped. Observed pattern in the 
-- C bucket is negative quantity, so quantity >= 0 is the violation here. Eyeball-derived;
-- below collapses the whole bucket to one row to test it at population scale. Price checked 
-- as in Section 10 (price > 0 expected). The negative line value comes from quantity, not price.
-- neg_price and zero_price split deliberately: unlike failures.

SELECT
     COUNT(*) AS total_cancel_rows,
     COUNT_IF(quantity >= 0) AS bad_quantity, 
     MIN(quantity) AS min_quantity,
     MAX(quantity) AS max_quantity,
     COUNT_IF(price < 0) AS neg_price,        
     COUNT_IF(price = 0) AS zero_price,
     MIN(price) AS min_price,
     MAX(price) AS max_price
FROM online_retail
WHERE invoice ILIKE 'C%';

-- Results: total_cancel_rows = 19,494 which agrees with what I got in Section 3. There is only 
-- one bad_quantity which I am guessing is the 1 that shows up for max_quantity. Will test in 13.1.
-- No zero prices, unlike in sales, and no negative prices. Two interesting results are the min_quantity
-- of -80,995 which seems to be the opposite of a sales quantity seen in Section 10 and a max_price
-- of 38,970 GBP. I'll look at both records in 13.1.

-- ---------------------------------------------------------------------------
-- 13.1  Cancelations Sanity Check Follow Up
-- ---------------------------------------------------------------------------
-- This will isolate the three rows discussed in Section 13
-- to see if I can figure out what they are.

SELECT 
    invoice,
    stock_code,
    description,
    quantity,
    price,
    customer_id,
    invoice_date
FROM online_retail
WHERE invoice ILIKE 'C%'
  AND (quantity >= 0 OR quantity = -80995 OR price = 38970.00);

-- Results: min_quantity is a cancelation of the 80,995 giant flagged in Section 10 and
-- characterized in Section 11. Same stock_code (23843), description, price (£2.08) and
-- customer_id (16446), 12 minutes apart. Section 11's "true business fact, not a distortion"
-- still holds for Q2 value, but the order did not stick, which Section 11 could not have known.
-- Cleanest cancelation-to-original pair in the dataset; useful Q3 test case.
-- Invoice numbering does NOT link a cancelation to its original. The sale is invoice 581483 and
-- the cancelation is C581484. Stripping the C yields 581484, a different invoice. One
-- counterexample rules out prefix-stripping as a matching key. First direct evidence for the
-- no-line-key premise that Section 9's (customer_id, stock_code) grain already assumed. Closes
-- off invoice-based matching only; the Q3 heuristic choice and event-level quantity accounting
-- are unaffected.
-- bad_quantity confirmed as the max_quantity = 1 row (C496350). Both it and the max_price row are
-- stock_code M, description "Manual", meaning they are manual employee entries, not products.
-- Conclusion: the C bucket is not purely customer cancelations. The M rows have no original to
-- reverse (Q3) and carry line value that nets against genuine cancelations (Q1): +£373.57 and
-- £38,970. Both price extremes being M means Section 13's max_price measures the contaminant,
-- not product prices. Second non-product code after "B" in Section 3; feeds the non-product
-- stock_code scan (still open). Exclusion deferred to 02_data_cleaning.sql.


-- ===========================================================================
-- SECTION 14 : NON-PRODUCT STOCK CODES
-- ===========================================================================
-- We know from Sections 3 and 13.1 that there are non-product stock_codes.
-- The question now is how many of them there are so we can separate product and non-product records later.

SELECT
    stock_code,
    COUNT(*) AS total_records
FROM online_retail
GROUP BY stock_code
ORDER BY total_records DESC;

-- Results: The code tells us that there are over 5K stock_codes used in the dataset. That's too many
-- to judge by eye so a different approach is needed. The next step is to see if there are any patterns
-- in how stock_codes are structured in terms of use of digits versus letter characters. The easiest way
-- to read that is by replacing digits with "D" and letters with "L". 

SELECT
    REGEXP_REPLACE(REGEXP_REPLACE(stock_code, '[A-Za-z]', 'L'), '[0-9]', 'D') AS code_pattern,
    COUNT(DISTINCT stock_code) AS distinct_codes,
    COUNT(*) AS total_records
FROM online_retail
GROUP BY code_pattern
ORDER BY distinct_codes DESC;

-- Results: From the start, this shows that the majority of stock_codes follow a pattern of either
-- five digits followed by an optional suffix of up to two letters. Those patterns cover 99.4% of the
-- records. The reason I included five digits followed by two letters is that there is no records with 
-- five digits followed by three letters which seems like the pattern was deliberately ended after the
-- two letter prefix. That leaves 62 distinct codes representing 6,093 records which don't follow this
-- majority pattern. I have flagged those for closer inspection in  Section 14.1 since I can't entirely 
-- rule out that they aren't product codes. 
-- Standing rule: Failing this shape test flags a code as a CANDIDATE for inspection, 
-- not as a non-product. The pattern marks the 62 to be looked at; it does not classify them. So 02 must
-- exclude on inspected list or row signature, never on a "failed the pattern" stock_code list.
-- Also important to note that, as found in Section 2, there are no NULL values in the stock_code field.


-- ---------------------------------------------------------------------------
-- 14.1  Outlier Follow Up
-- ---------------------------------------------------------------------------
-- This query will look at the 62 outlier codes from Section 14. This will give
-- me a better idea what they are for. 

SELECT
    stock_code,
    LENGTH(stock_code) AS code_length,
    COUNT(*) AS total_records,
    COUNT(DISTINCT description) AS distinct_descriptions,
    MIN(description) AS sample_description,
    SUM(quantity * price) AS net_line_value
FROM online_retail
WHERE NOT REGEXP_LIKE(stock_code, '[0-9]{5}[A-Za-z]{0,2}')
GROUP BY stock_code, code_length
ORDER BY ABS(SUM(quantity * price)) DESC;   

-- Results: 62 outlier codes, sorted top-down by magnitude into exclude / keep / stray.
--
-- EXCLUDE (non-products): DOT (+322,647, DOTCOM postage), AMAZONFEE (-260,764, marketplace
-- fee), POST (+112,341, postage), M/m (1,426 recs, -82,781, full pop incl. the two from
-- 13.1), BANK CHARGES (-35,563), D (discount, -13,485), C2 (carriage, +13,386), CRUK
-- (charity, -7,933), ADJUST/ADJUST2 (ledger, +7,566), S (samples, -6,066), TEST001/002
-- (test products, +204). B (-147,614) already cut via Section 3.
--   These don't net to one total. DOT/POST/C2 are sales-side positives, AMAZONFEE/B/M
--   negatives. What matters is WHERE they live: DOT/POST/C2 sit in SALES (they inflate the
--   Q2 denominator and rank as fake products), while M nets into CANCELATIONS (13.1) and
--   pollutes the canceled ranking. Non-products on both sides mean the non-product
--   exclusion runs whole-table, not just C.
--
-- VOUCHERS: gift_0001_10.._90 (9 codes, 100 recs, +1,687). DECISION: exclude. A voucher is
-- stored value redeemed later against real merchandise, not a unit of merchandise, so
-- counting it in Q2 would double-count.
--
-- KEEP (real products, fail shape test): PADS (cushion pads), SP1002 (chalkboard). Confirmed
-- in Section 14.3. Standing caveat: failing the shape test flags a CANDIDATE, not a non-product.
--
-- There also appears to be an additional block of stock_codes starting with "DCGS" that 
-- may still be product codes despite not fitting the pattern. Will look at those in Section 14.2.
--
-- STRAYS: GIFT, C3. Zero value, left to the zero-price rule, not named.



-- ---------------------------------------------------------------------------
-- 14.2  DCGS Drill Down
-- ---------------------------------------------------------------------------
-- Checking to see if the block of codes identified in Section 14.1 are product codes
-- that are missed by the pattern established in Section 14. I've also added a check for the junk record
-- pattern seen in Section 2.

SELECT
    stock_code,
    LENGTH(stock_code) AS code_length,
    COUNT(*) AS total_records,
    COUNT(DISTINCT description) AS distinct_descriptions,
    MIN(description) AS sample_description,
    SUM(quantity * price) AS net_line_value,
    COUNT(CASE WHEN price = 0 THEN 1 END) AS no_price_records,
    COUNT(customer_id) AS records_with_customer,
    COUNT(CASE WHEN (price = 0)
                AND customer_id IS NULL THEN 1 END) AS junk_records
FROM online_retail
WHERE stock_code ILIKE 'DCGS%'
GROUP BY stock_code, code_length
ORDER BY junk_records DESC, ABS(SUM(quantity * price)) DESC;  

-- Results: 34 DCGS codes, 158 records, and NOT ONE carries a customer_id. The whole
-- block is anonymous. 16 codes carry real net value (real SKU, description, price:
-- GIRLS PARTY BAG, dog collars, etc.). 18 are pure zero-value junk. So DCGS is a real
-- product prefix the pattern missed. The standing rule still holds. Failing the shape
-- test flags a code for inspection, it does not classify it non-product.
-- BUT the split is NOT clean at code level. 12 of the 16 real codes also contain junk
-- rows (DCGSSGIRL = 23 real PARTY BAG lines + 2 junk). Junk is a ROW property, not a
-- code property. Row level: 125 real priced lines, 33 junk (price = 0, no customer).
-- 18 from the pure-junk codes, 15 riding inside the real codes. This is why 02 filters
-- on the row signature (Section 12.2), NOT a stock_code drop-list. Dropping DCGSSGIRL would
-- delete 23 real sales.
-- Every DCGS row is customer-null, so here "price = 0 AND customer_id IS NULL" reduces
-- to "price = 0". Price is the discriminator in this block. (Section 12.2 holds overall. The
-- customer-null clause is just constant here.) The 125 real lines are kept by the zero-price
-- rule but anonymous, so they fall out of customer-level Q2 like the Section 4 share.


-- ---------------------------------------------------------------------------
-- 14.3  Non-DCGS Codes
-- ---------------------------------------------------------------------------
-- Now for the codes that don't include "DCGS".

SELECT
    stock_code,
    LENGTH(stock_code) AS code_length,
    COUNT(*) AS total_records,
    COUNT(DISTINCT description) AS distinct_descriptions,
    MIN(description) AS sample_description,
    SUM(quantity * price) AS net_line_value,
    COUNT(CASE WHEN price = 0 THEN 1 END) AS no_price_records,
    COUNT(customer_id) AS records_with_customer,
    COUNT(CASE WHEN (price = 0)
                AND customer_id IS NULL THEN 1 END) AS junk_records
FROM online_retail
WHERE NOT REGEXP_LIKE(stock_code, '[0-9]{5}[A-Za-z]{0,2}')
  AND stock_code NOT ILIKE 'DCGS%'
GROUP BY stock_code, code_length
ORDER BY junk_records DESC, ABS(SUM(quantity * price)) DESC;

-- Results: the non-DCGS complement. No new exclusions surface here. Every non-product
-- in this set was already named in 14.1, so this query's job is the junk-row check on
-- the two keep-candidates and a confirmation that the partition holds.
--
-- PADS: 19 records, 18 zero-price, ALL 19 customer-attached, 0 junk. This is the 12.2
-- case, not the DCGS case. The 18 zero-price rows survive because they fail the junk
-- condition on the customer clause (customer attached), exactly like the 89 rows in
-- 12.2. PADS is a real product (cushion pads) whose lines are mostly free/promo. The
-- zero-price rule keeps all 19 on its own, no special handling. KEEP confirmed.
--
-- SP1002: 3 records, 1 zero-price / no-customer / junk, 2 real priced-and-attached
-- lines. This IS the DCGS case: a real code (KID'S CHALKBOARD) carrying one junk row.
-- The zero-price rule strips the 1 junk row and keeps the 2 real sales. KEEP confirmed.
--
-- So the two keeps survive for different reasons, both already established: PADS via
-- 12.2 (zero-price but customer-attached, all kept), SP1002 via 14.2 (real code, one
-- junk row stripped). Neither is a non-product; neither needs a named exclusion.
--
-- Vouchers (gift_0001_*) reappear here: every voucher row is customer-null (like DCGS),
-- so the zero-value denominations fall to the zero-price rule regardless, and the named
-- exclusion (14.1 decision) removes the priced voucher rows. Nothing here contradicts
-- exclude.


-- ===========================================================================
-- VALIDATION COMPLETE
-- ===========================================================================
-- Deferred decisions collected for 02_data_cleaning.sql and 03_data_analysis.sql.
--
-- To 02_data_cleaning.sql:
--   Zero-price rule: drop price = 0 AND customer_id IS NULL. One decision covering the
--     Section 2 null-description junk, the Section 10 zero-price sales, the Section 11.3
--     positive zero-price giants, and the Section 12 negative write-offs. Row-level,
--     unrestricted by sign (12.1). Retains the 89 customer-attached zero-price sales (12.2),
--     which fail the condition and so are kept automatically.
--   Non-product exclusion: named stock_code list, applied whole-table not just the C bucket
--     (DOT/POST are sales-side). List from 14.1. Keep-list (exclude from neither rule): the
--     16 real DCGS SKUs (14.2), PADS and SP1002 (14.3).
--   Exclude adjustments as ledger corrections; also clears 'B' (Section 3).
--   Retain duplicates; deduping would delete real units purchased (Section 7).
--   Surrogate key on the clean layer (Section 5).
--   Materialize the record_type C/A column, repeated across Sections 8 and 9.
--
-- To 03_data_analysis.sql:
--   Q3 cancelation-to-original matching heuristic. No line key (Section 13.1, the C581484/581483
--     counterexample); requires event-level quantity accounting so one sale isn't claimed twice.
--   Partial-cancelation handling (Section 9).
--   Dec 2010 - Jan 2011 cancelation-value concentration: product or customer (Section 8, Q2).