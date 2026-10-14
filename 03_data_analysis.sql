/* ========================================================================= *
   SCRIPT   : 03_data_analysis.sql
   PURPOSE  : Answer four questions about cancelations: how large the issue
              is, where its value concentrates (product vs customer), how
              quickly orders are canceled, and where an intervention should point.
   DATASET  : Online Retail II (UCI dataset 502)
   DEPENDS  : online_retail_clean_filtered (view built in 02_data_cleaning.sql)
   OUTPUTS  : Q4 recommendation: customer-first outreach to the top 10
              canceling accounts, measured over a ~90-day window.
   ======================================================================== */


-- ===========================================================================
-- VIEW CHECK
-- ===========================================================================   

-- First, I just want to double-check that the view I created in data cleaning is
-- live. Just a reminder that this view filters out adjustment type records and
-- identified non-products.

SELECT *
FROM online_retail_clean_filtered;

-- The query returns the newly created view with all records accounted for. Time to move
-- on to the analysis.

-- ===========================================================================
-- Q1: SIZE OF THE ISSUE BY VALUE AND UNITS
-- ===========================================================================

-- How large is the issue by value and units?
-- This question establishes if the issue is even worth caring about in the first place.
-- The problem needs to be quantified to decide if it is even worth the time or effort of
-- dealing with. To do this, we need to look at gross sales and cancelations. 
--
-- In finance, gross sales are total sales before any deductions. Since cancelations can
-- be classified as a deduction, they don't factor into gross sales. I decided the cleanest
-- way to do this next part is to separate sales and cancelations into CTEs and then use a
-- cross join to bring them together in the main query and calculate what percentage cancelations
-- represent of sales. Since I'd like a nice rounded percentage for units and units is stored in 
-- data type INT, I'll also cast that to type FLOAT for the ratio.

WITH c AS (
    SELECT
        ABS(SUM(quantity * price)) AS total_cancel_value,
        ABS(SUM(quantity)) AS total_cancel_units
    FROM online_retail_clean_filtered
    WHERE record_type = 'cancelation'
),
s AS (
    SELECT
        SUM(quantity * price) AS total_sale_value,
        SUM(quantity) AS total_sale_units
    FROM online_retail_clean_filtered
    WHERE record_type = 'sale'
)
SELECT
    s.total_sale_value AS gross_sales,
    s.total_sale_units AS gross_sale_units,
    c.total_cancel_value AS total_cancelations_in_value,
    c.total_cancel_units AS total_cancelations_in_units,
    ROUND(c.total_cancel_value / s.total_sale_value * 100, 2) AS cancel_value_pct_of_gross,
    ROUND(c.total_cancel_units / s.total_sale_units::FLOAT * 100, 2) AS cancel_units_pct_of_gross
FROM s
CROSS JOIN c;

-- Results: The value of cancelations comes in at 3.61% the value of gross sales, or 726,555.99 GBP. The
-- number of units canceled comes in at 4.35% of gross sales units, or 481,891 units. Canceled units 
-- making up a higher share of gross sales units (4.35%) than cancelation value does of gross sales value 
-- (3.61%) suggests cancelations skew toward lower-priced items on average.
-- As only a single-digit share of revenue, cancelations are not an emergency in aggregate. Whether they
-- are still worth addressing depends on how concentrated that value is. A small total driven mostly by a
-- few products or accounts could be a cheap, high-value fix. That concentration question is Q2.
-- Caveat: unit totals include flagged zero-price junk rows (see 02 view note), so the units
-- share is approximate. Value figures are unaffected.

-- ===========================================================================
-- Q2: PRODUCT VS CUSTOMER CONCENTRATION
-- ===========================================================================

-- Of the cancelation value, how much is concentrated in a few products vs a few customers?
-- I feel the best way to answer this question is in a "count to a threshold" format. For example,
-- ranking each product or customer's share of the total cancelation value from highest to lowest, how 
-- many products or customers does it take to cover 50% of the cancelation value? Or 80%? That format
-- can give you a better idea of the shape of the distribution. 
-- This question needs to be tackled in two parts, with one part looking at the product side and the
-- other at the customer side. 

-- ---------------------------------------------------------------------------
-- Q2.1  Product-side concentration curve
-- ---------------------------------------------------------------------------

-- I'll start with the product side. I feel that CTEs make code cleaner and more readable, so I'll use
-- CTEs again here. One CTE will handle calculating the total cancelation value for each product in
-- the dataset. The next will use SUM(...) OVER (...) window functions. One ordered by cancelation
-- value descending to build a running total (each product plus everything ranked above it), and one
-- over the full set for the grand total. I'll also use ROW_NUMBER() to rank the products so "how many"
-- is countable. Those values can then be used to calculate the cumulative share in the main query.

WITH per_product AS (
    SELECT
        stock_code AS product,
        ABS(SUM(quantity * price)) AS cancel_value
    FROM online_retail_clean_filtered
    WHERE record_type = 'cancelation'
      AND is_null_customer = FALSE
    GROUP BY stock_code
),
ranking AS (
    SELECT
        product,
        cancel_value,
        SUM(cancel_value) OVER(ORDER BY cancel_value DESC)::FLOAT AS running_total,
        SUM(cancel_value) OVER()::FLOAT AS grand_total,
        ROW_NUMBER() OVER(ORDER BY cancel_value DESC) AS product_rank
    FROM per_product
)
SELECT
    product,
    cancel_value,
    product_rank,
    running_total / grand_total AS cumulative_share
FROM ranking
ORDER BY product_rank;

-- Results: cancelation value spans 2,842 distinct products (attributable slice, is_null_customer
-- = FALSE, so 100% = 719,689.58 GBP). Concentration is high. The top 27 products (0.95%) account
-- for 50% of cancelation value, and the top 310 (10.9%) account for 80%. Sharp head, long tail.
-- A small cluster of products drives half the cancelation value while the remainder is spread thin.
-- Whether this makes cancelations a "product problem" depends on the customer curve for comparison (below)
-- and cannot be concluded from the product side alone.

-- ---------------------------------------------------------------------------
-- Q2.2  Cancelation value with no customer_id
-- ---------------------------------------------------------------------------

-- Now we do the same thing for the customer side. 
-- First we should look at what portion of the cancelation value can't be attributed to a
-- customer, since 01_data_validation noted that not all records have a customer_id value attached. 

SELECT
    ABS(SUM(quantity * price)) AS no_cust_cancel_value,
    ABS(SUM(quantity * price)) / (
        SELECT ABS(SUM(quantity * price))
        FROM online_retail_clean_filtered
        WHERE record_type = 'cancelation'
    ) * 100 AS pct_of_total_cancel_value
FROM online_retail_clean_filtered
WHERE record_type = 'cancelation'
  AND is_null_customer = TRUE;

-- Results: So this tells us that out of the 726,555.99 GBP total value for cancelations, 6,866.41 GBP
-- in value comes from records with no customer_id which therefore can't be attributed to a specific
-- customer. That's 0.94% of the total value, meaning any calculation that excludes those records still
-- covers 99.06% of the total cancelation value. 


-- ---------------------------------------------------------------------------
-- Q2.3  Customer-side concentration curve
-- ---------------------------------------------------------------------------

-- Now I do the customer side of Q2, a mirror of the product query. I've kept everything nearly identical
-- so the two curves are easier to compare. The only change from the product version is GROUP BY customer_id
-- instead of stock_code. Both curves use the same is_null_customer = FALSE filter, so they share a denominator.

WITH per_customer AS (
    SELECT
        customer_id AS customer,
        ABS(SUM(quantity * price)) AS cancel_value
    FROM online_retail_clean_filtered
    WHERE record_type = 'cancelation'
      AND is_null_customer = FALSE
    GROUP BY customer_id
),
ranking AS (
    SELECT
        customer,
        cancel_value,
        SUM(cancel_value) OVER(ORDER BY cancel_value DESC)::FLOAT AS running_total,
        SUM(cancel_value) OVER()::FLOAT AS grand_total,
        ROW_NUMBER() OVER(ORDER BY cancel_value DESC) AS customer_rank
    FROM per_customer
)
SELECT
    customer,
    cancel_value,
    customer_rank,
    running_total / grand_total AS cumulative_share
FROM ranking
ORDER BY customer_rank;

-- Results: cancelation value spans 2,445 distinct customers. Again, concentration is high.
-- The top 10 customers (0.41%) account for 50% of cancelation value, and the top 191
-- (7.81%) account for 80%.
-- Like the product curve, this runs on the attributable slice (100% = 719,689.58 GBP). The
-- 6,866.41 GBP / 0.94% with no customer_id (see null check above) is excluded from both.
-- Product-vs-customer comparison deferred to the Q2 verdict below.

-- ===========================================================================
-- Q2 VERDICT: PRODUCT VS CUSTOMER CONCENTRATION
-- ===========================================================================

-- Product side: top 27 of 2,842 (0.95%) -> 50% of attributable cancelation value, top 310
--   (10.9%) -> 80%. Sharp head, long tail.
-- Customer side: top 10 of 2,445 (0.41%) -> 50% of attributable cancelation
--   value, top 191 (7.81%) -> 80%. Sharper than the product curve at both
--   crossovers, ~2.3x tighter at the 50% head.
-- Both curves share the same denominator: 719,689.58 GBP attributable (excludes the
--   6,866.41 GBP / 0.94% with no customer_id).
-- Conclusion: customer concentration exceeds product concentration, which means
-- the problem is customer-side. Both curves are steep, but the customer head is 
-- the tighter lever. The top 10 customers alone carry 50% of attributable cancelation
-- value. A customer-targeted intervention hits more value per target than a product-targeted one.
-- Whether the sharp customers are canceling the sharp products is a mechanism question -> deferred 
-- to Q4.


-- ===========================================================================
-- Q3: TIME FROM ORDER TO CANCELATION
-- ===========================================================================

-- For those cancelations, how quickly after the original order do they happen?
-- This question will be the trickiest to tackle. As covered in data validation, you can't match
-- cancelation records to sale records by simply removing the "C" prefix from the invoice value for the
-- cancelation and finding a sale record with an identical invoice value. 
-- Instead, the link has to be rebuilt from the natural columns. I will self-join the view onto itself,
-- treating one copy as the cancelations and the other as the sales, and match on customer_id,
-- stock_code, and quantity with the sign flipped (cancelations are stored negative, sales positive),
-- requiring the sale to be dated on or before the cancelation. Because cleaning kept no unique line
-- id, one cancelation can match several candidate sales (repeat purchases of the same item, plus
-- retained byte-identical duplicate rows). So I'll pick a single original per cancelation. I'll use the
-- most recent qualifying sale, using row_key only to break ties when two candidates share a timestamp
-- (row_key is never a join key). Cancelations with no customer_id can't be matched and are excluded,
-- so this runs on the same attributable slice as the Q2 customer side. The timing result therefore only
-- describes cancelations we can match to an original sale, so match coverage is checked separately
-- before drawing any conclusion.


WITH cancel_match AS (
    SELECT
        c.row_key AS cancel_key,
        c.customer_id AS customer,
        c.stock_code AS product,
        s.invoice_date AS sale_date,
        c.invoice_date AS cancel_date,
        ROW_NUMBER() OVER(
            PARTITION BY c.row_key
            ORDER BY s.invoice_date DESC, s.row_key) AS match_rank
    FROM online_retail_clean_filtered AS c
    JOIN online_retail_clean_filtered AS s
      ON s.record_type = 'sale'
      AND s.customer_id = c.customer_id
      AND s.stock_code = c.stock_code
      AND s.quantity = -c.quantity
      AND s.invoice_date <= c.invoice_date
    WHERE c.record_type = 'cancelation'
      AND c.is_null_customer = FALSE
)
SELECT
    cancel_key,
    customer,
    product,
    sale_date,
    cancel_date,
    DATEDIFF('day', sale_date, cancel_date) AS days_to_cancel
FROM cancel_match
WHERE match_rank = 1
ORDER BY days_to_cancel;

-- Results: 6516 cancelations matched to an originating sale (one row each, the match_rank = 1 pick). 
-- days_to_cancel spans 0 to 723 days. The link is rebuilt from the natural fingerprint, not a true key, so 
-- it carries two known limits. First, exact-quantity matching (s.quantity = -c.quantity) captures only full
-- cancelations. Partial cancelations (cancel fewer units than were bought) cannot match and are absent 
-- from this set, which biases it toward whole-order cancelations. Second, the join has a lower time bound 
-- (sale on or before cancel) but NO upper bound, and the dataset records no cancelations policy, so a 
-- cancelation whose true origin is a partial or non-fingerprint sale can link instead to a coincidental 
-- older exact-quantity sale. This produces a thin tail of implausibly long gaps (max 723 days, a 2009 sale 
-- matched to a 2011 cancel). These are not fixable from this data, so they are handled downstream: the 
-- aggregation leads with the median and buckets the tail rather than trusting the mean or max, and coverage 
-- is quantified in the check below.

 
-- ---------------------------------------------------------------------------
-- Q3.1  Timing distribution summary
-- ---------------------------------------------------------------------------

WITH cancel_match AS (
    SELECT
        c.row_key AS cancel_key,
        c.customer_id AS customer,
        c.stock_code AS product,
        s.invoice_date AS sale_date,
        c.invoice_date AS cancel_date,
        ROW_NUMBER() OVER(
            PARTITION BY c.row_key
            ORDER BY s.invoice_date DESC, s.row_key) AS match_rank
    FROM online_retail_clean_filtered AS c
    JOIN online_retail_clean_filtered AS s
      ON s.record_type = 'sale'
      AND s.customer_id = c.customer_id
      AND s.stock_code = c.stock_code
      AND s.quantity = -c.quantity
      AND s.invoice_date <= c.invoice_date
    WHERE c.record_type = 'cancelation'
      AND c.is_null_customer = FALSE
),
matched_gaps AS (
    SELECT
        cancel_key,
        customer,
        product,
        sale_date,
        cancel_date,
        DATEDIFF('day', sale_date, cancel_date) AS days_to_cancel
    FROM cancel_match
    WHERE match_rank = 1
)
SELECT
    ROUND(MEDIAN(days_to_cancel), 2) AS median_days,
    MIN(days_to_cancel) AS min_days,
    MAX(days_to_cancel) AS max_days,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (
        ORDER BY days_to_cancel), 2) AS p90_days,
    COUNT_IF(days_to_cancel = 0) AS same_day,
    COUNT_IF(days_to_cancel BETWEEN 1 AND 7) AS day_1_7,
    COUNT_IF(days_to_cancel BETWEEN 8 AND 30) AS day_8_30,
    COUNT_IF(days_to_cancel BETWEEN 31 AND 90) AS day_31_90,
    COUNT_IF(days_to_cancel > 90) AS day_90_plus
FROM matched_gaps;

-- Results: median 12 days -> the typical cancelation resolves in under two weeks. Median is the headline, 
-- not the mean, because the distribution is right-skewed (the false-positive tail above drags any mean-
-- based measure up). 
-- Distribution: same-day 1263 (19.4%), 1-7 days 1514, 8-30 days 1843, 31-90 days 1171, 90-plus 725. Buckets
-- sum to 6516 (every matched row placed once). Cumulatively, 70.9% resolve within 30 days and 88.9% within 90.
-- The 90-plus bucket (725, 11.1%) is the mixed zone where genuine late cancelations and fingerprint
-- false-positives are indistinguishable, so it is reported as a bucket, not read as a cancelation window.
-- P90 lands at 105.5 days, past the plausible window, which is itself a symptom of that tail rather than
-- a clean spread measure, so the tail is characterized by the cumulative bucket shares (88.9% within 90) instead.
-- Note: bucket shares are counts of matched cancelations, not value-weighted. The matched set covers 78% of
-- attributable cancelation value (see Q3.2), so these timings describe the larger cancelations, but the percentages
-- themselves are shares of matched rows.


-- ---------------------------------------------------------------------------
-- Q3.2  Match coverage check
-- ---------------------------------------------------------------------------

-- The timing stats above describe only the 6516 cancelations that matched an originating
-- sale, so before generalizing them we need to know how much of the cancelation problem that matched set
-- represents. This query measures the match rate over the attributable cancelations two ways, by row
-- count and by value, because the two can diverge and that divergence is what decides how the timing
-- result may be framed: by count it would speak for most cancelations, by value only for a share of
-- cancelation value. Within the attributable set a cancelation goes unmatched when it has no qualifying
-- exact-quantity prior sale (a partial cancelation, or an original that predates the data window). Null-
-- customer cancelations sit outside this denominator entirely, excluded upstream and quantified at 0.94% of 
-- value in the Q2 null check. has_match flags each attributable cancelation, and the outer query counts and
-- value-weights the matched share.

SELECT
    COUNT(*) AS attributable_cancel_rows,
    COUNT_IF(has_match) AS matched_cancel_rows,
    ROUND(COUNT_IF(has_match) / COUNT(*)::FLOAT * 100, 2) AS pct_rows_matched,
    ROUND(
        ABS(SUM(CASE WHEN has_match THEN quantity * price ELSE 0 END))
        / ABS(SUM(quantity * price)) * 100, 2
    ) AS pct_value_matched
FROM (
    SELECT
        c.quantity,
        c.price,
        EXISTS (
            SELECT 1
            FROM online_retail_clean_filtered s
            WHERE s.record_type = 'sale'
              AND s.customer_id = c.customer_id
              AND s.stock_code = c.stock_code
              AND s.quantity = -c.quantity
              AND s.invoice_date <= c.invoice_date
        ) AS has_match
    FROM online_retail_clean_filtered c
    WHERE c.record_type = 'cancelation'
      AND c.is_null_customer = FALSE
);

-- Results: 17934 attributable cancelations, 6516 matched -> 36.33% by COUNT but 78.08% by VALUE. The
-- split is the key finding: matches skew to large cancelations, misses skew small. Both fingerprint
-- limits point the same way: exact-quantity matching drops partial cancelations (typically smaller), and
-- left-censored sales (originals predating the data window) drop whole matches. So the matched set is
-- weighted toward the large cancelations that carry most of the value. The Q3 timing result speaks for
-- that high-value majority, not for small cancelations. The bucket percentages remain shares of matched
-- cancelations by count.

-- ===========================================================================
-- Q3 VERDICT: TIME FROM ORDER TO CANCELATION
-- ===========================================================================

-- The typical cancelation resolves in 12 days (median, not mean, because the right-skewed tail drags any 
-- mean-based measure up). 19.4% are same day, 70.9% within 30 days, 88.9% within 90; the remaining 11.1% 
-- sit 90-plus days out, a grey zone where genuine late cancelations and fingerprint false positives are 
-- indistinguishable.
-- Coverage: 6516 of 17934 attributable cancelations matched. 36.33% by count but 78.08% by value. Matches 
-- skew to large cancelations, misses skew small. The figures above are shares of matched cancelations by 
-- count. Because the matched set covers 78% of cancelation value, they describe the timing of the large
-- cancelations that matter most.
-- Conclusion: Matched cancelations resolve on a short horizon. The matched cancelations, which carry 78%
-- of cancelation value, resolve fast: 88.9% inside 90 days, with the long tail thin and artifact-mixed 
-- rather than a genuine slow-return signal. Timing is a short-window effect, which sets the timescale 
-- on which a Q2-style customer-targeted intervention would be observable. Whether the concentrated 
-- cancelers are the ones driving the fast, high-value cancelations is the mechanism question carried 
-- from Q2, still open, addressed in Q4.

-- ===========================================================================
-- Q4: WHERE TO INTERVENE AND WHAT IT IS WORTH
-- ===========================================================================

-- Given the answers to Q2 and Q3 together, where should any intervention point and what is it worth?
-- While Q2 noted that the customer share of the issue is larger, it also raised the question of if those
-- top customers are also canceling top products. If that is the case, you can potentially address both
-- customer side and the product side by only addressing the customer side.
-- To do this, we have to create a query that looks at the cancelation value share of the top customers
-- and measures how much of the top customers' cancelation value falls on top products, compared against the 
-- share top products hold of all cancelation value. The query breaks up into a block creating a base 
-- layer of unaggregated cancelation rows, another with the share of cancelation value per customer
-- then limiting that list to just the top customers that cover 50% of the cancelation value, one with the 
-- share of cancelation value per product, then limiting that list to just the top products that cover 50% 
-- of the cancelation value, then a block that aggregates the rows where the top customers and the top 
-- products overlap, and the final block that calculates and compares the overlapping cancelation share to a
-- baseline of the share of the cancelation value covered by the top products as calculated previously
-- in the same query as a sanity check.
--
-- Note: Top products here match Q2 exactly (27 of 2,842, 0.95%), since both draw from the same
-- attributable base. Still less concentrated than the customer side, where the top 10 (0.41%)
-- hold 50% of cancelation value.


WITH cancel_rows AS(
    SELECT *
    FROM online_retail_clean_filtered
    WHERE record_type = 'cancelation'
    AND is_null_customer = FALSE
),
per_customer AS (
    SELECT
        customer_id AS customer,
        ABS(SUM(quantity * price)) AS cancel_value
    FROM cancel_rows
    GROUP BY customer_id
),
cust_share AS(
    SELECT
        customer,
        cancel_value,
        SUM(cancel_value) OVER(ORDER BY cancel_value DESC, customer)::FLOAT AS running_total,
        SUM(cancel_value) OVER()::FLOAT AS grand_total,
        ROW_NUMBER() OVER(ORDER BY cancel_value DESC, customer) AS customer_rank
    FROM per_customer         
),
top_cust AS (
    SELECT
        customer,
        cancel_value,
        customer_rank,
        running_total / grand_total AS cumulative_share
    FROM cust_share
    WHERE (running_total - cancel_value) / grand_total < 0.5
),
per_product AS (
    SELECT
        stock_code AS product,
        ABS(SUM(quantity * price)) AS cancel_value
    FROM cancel_rows
    GROUP BY stock_code
),
prod_share AS (
    SELECT
        product,
        cancel_value,
        SUM(cancel_value) OVER(ORDER BY cancel_value DESC, product)::FLOAT AS running_total,
        SUM(cancel_value) OVER()::FLOAT AS grand_total,
        ROW_NUMBER() OVER(ORDER BY cancel_value DESC, product) AS product_rank
    FROM per_product
),
top_prod AS (
    SELECT
        product,
        cancel_value,
        product_rank,
        running_total / grand_total AS cumulative_share
    FROM prod_share
    WHERE (running_total - cancel_value) / grand_total < 0.5
),
agg_sums AS (
    SELECT
        ABS(SUM(quantity * price)) AS total_value,
        ABS(SUM(CASE WHEN customer_id IN (SELECT customer FROM top_cust) THEN (quantity * price)
                     ELSE 0 END)) AS cust_value,
        ABS(SUM(CASE WHEN customer_id IN (SELECT customer FROM top_cust) 
                          AND stock_code IN (SELECT product FROM top_prod) THEN (quantity * price)
                     ELSE 0 END)) AS overlap_value,             
        ABS(SUM(CASE WHEN stock_code IN (SELECT product FROM top_prod) THEN (quantity * price)
                     ELSE 0 END)) AS prod_value
    FROM cancel_rows
)
SELECT
    ROUND(overlap_value / cust_value * 100, 2) AS overlap_share,
    ROUND(prod_value / total_value * 100, 2) AS baseline_share,
    cust_value,
    prod_value,
    overlap_value,
    total_value
FROM agg_sums;    

-- Results: Of the top 10 customers' cancelation value (365,285.52 GBP), 78.96% falls on the top 27 
-- products, against a baseline of 50.28% (the top products' share of all cancelation value), roughly 1.57x 
-- the rate expected if cancelations were spread independently. The overlap is near-symmetric. 79.71% of top-
-- product value also comes from top customers. So the concentrated cancelers and the concentrated canceled-
-- products are largely the same corner of the data. This answers the mechanism question deferred from Q2: a 
-- customer-first intervention would also reach most of the product concentration, so product is largely 
-- subsumed rather than a separate problem.


-- ---------------------------------------------------------------------------
-- Q4.1  Sizing query (attributable gross sales)
-- ---------------------------------------------------------------------------

-- This is the Q1 gross-sales query re-run with is_null_customer = FALSE on BOTH the sale and cancelation
-- CTEs, so numerator and denominator sit on the same attributable slice. Value only, since the verdict cites
-- value not units. Produces the 4.13% figure. Kept here rather than folded into Q1 because this attributable
-- cut only became the relevant denominator once Q4 fixed the intervention on attributable customers.

WITH c AS (
    SELECT ABS(SUM(quantity * price)) AS total_cancel_value
    FROM online_retail_clean_filtered
    WHERE record_type = 'cancelation'
      AND is_null_customer = FALSE
),
s AS (
    SELECT SUM(quantity * price) AS total_sale_value
    FROM online_retail_clean_filtered
    WHERE record_type = 'sale'
      AND is_null_customer = FALSE
)
SELECT
    s.total_sale_value AS attributable_gross_sales,
    c.total_cancel_value AS attributable_cancelations,
    ROUND(c.total_cancel_value / s.total_sale_value * 100, 2) AS cancel_value_pct_of_gross
FROM s
CROSS JOIN c;

-- Results: attributable cancelations 719,689.58 GBP against attributable gross sales
-- 17,434,464.73 GBP -> 4.13%, up from the 3.61% full-set figure in Q1. The lift comes from
-- dropping null-customer records from both sides, which trims more sale value than cancelation
-- value. Used in the Q4 verdict to size the intervention ceiling. Not a new finding on its own.

-- ===========================================================================
-- Q4 VERDICT: WHERE TO INTERVENE AND WHAT IT IS WORTH
-- ===========================================================================

-- Finding: of the top 10 customers' cancelation value (365,285.52 GBP), 78.96% falls on the
-- top 27 products, against a 50.28% baseline (the top products' share of all attributable
-- cancelation value). Roughly 1.57x the rate expected under independence, and near-symmetric
-- (79.71% of top-product value also comes from top customers). The concentrated cancelers and
-- the concentrated canceled products are largely the same corner of the data, so product
-- concentration is largely SUBSUMED by customer concentration, not a separate problem.
-- Caveat: subsumed is not identity. ~21% of top-customer value (76,853.99 GBP) sits off the top
-- products, and some top-product value comes from non-top customers, so a residual product tail
-- survives. The 50.28% baseline is ~half BY CONSTRUCTION (the product head is cut at 50%), so it
-- is the yardstick 78.96 beats, not evidence that products carry more value. And this is a
-- targeting call about where value sits, NOT a claim about WHY these customers cancel. The
-- behavioral mechanism is still unexamined.
-- Synthesis (Q2 + this + Q3): Q2 put customers as the more concentrated lever (top 10 -> ~50% of
-- attributable value). This query shows those sharp customers largely ARE the sharp products, so
-- acting on customers folds in most of the product concentration. One intervention, not two. Q3
-- puts the effect on a short horizon (median 12 days, ~89% of matched cancelations within 90), so it is
-- observable on a ~90-day window.
-- What it is worth: the top 10 customers carry 365,285.52 GBP, of which 288,431.53 GBP sits on the
-- top products, so a customer-first action targets ~half of all attributable cancelation value
-- (719,689.58 GBP) and pulls in ~80% of the top products' cancelation value as a by-product. No
-- separate product workstream to run.
-- Sizing (Q1 cross-reference): re-running the Q1 gross-sales query on customer-attributable records
-- in BOTH numerator and denominator lifts cancelation value to 4.13% of attributable gross sales
-- (719,689.58 / 17,434,464.73 GBP), up from the 3.61% full-set figure. That 4.13% is the WHOLE
-- attributable pool. The top-10 slice targeted here is 365,285.52 / 17,434,464.73 = ~2.10% of
-- attributable gross sales. Two ceilings, both maxima: direct recovery of the top 10 caps near ~2
-- points of gross sales, while a systemic fix that generalizes across the base approaches the full
-- ~4 points. Real recovery is a fraction of either. Consistent with Q1: worth a look, not an
-- emergency.

-- ===========================================================================
-- RECOMMENDATION
-- ===========================================================================

-- Focus on the customer side, most impact for least action. The value is
-- concentrated enough that the whole priority is ~10 customers, a manageable and narrowly scoped
-- effort against the size of this business, and covering them also covers ~80% of the top-27
-- products' cancelation value for free. First step: have the business development leads who own
-- these accounts open a conversation, or send a focused survey, to probe why these specific
-- customers cancel. Is there something in what is offered, how it is offered, or how it is shipped
-- that could reduce their cancelations? If it is fixable the upside is a couple of points of gross
-- sales, more if the cause generalizes. If not, the cost was one round of outreach and a closed
-- growth question. Measure over ~90 days per the Q3 horizon.

