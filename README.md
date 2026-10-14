# Retail Cancellation Analysis: Customer Problem or Product Problem?

An end-to-end SQL analysis in Snowflake of the Online Retail II dataset, built to answer one operational question: **should an operations team focus on specific products or specific customers to reduce order cancellations?**

**Answer: customers.** 10 customers (0.4% of 2,445) account for half of attributable cancellation value. Those same customers account for most of the product-side concentration, so one targeted outreach effort covers both.

---

## The business question

Cancellations cost an online retailer revenue, but an operations team can't chase every one. Before deciding where to act, I wanted to answer four questions in order:

1. **Is it worth addressing?** How large is the problem by value and units?
2. **Where is it concentrated?** Do a few products or a few customers drive most of the cancellation value?
3. **How fast does it happen?** How long after the original order do cancellations occur?
4. **Where should the team intervene, and what is it worth?**

## Data

- **Source:** [Online Retail II](https://archive.ics.uci.edu/dataset/502/online+retail+ii), UCI Machine Learning Repository
- **Scope:** 1,067,371 transaction lines from a UK-based online gift retailer, December 2009 to December 2011 (25 months, no gaps)
- **Fields:** invoice, stock code, description, quantity, invoice date, price, customer ID, country

## Key findings

| Question | Finding |
|---|---|
| **Size** | Cancellations total **£726,556**, or **3.61%** of gross sales value. Not an emergency, but large enough to be worth a targeted fix. |
| **Concentration** | Measured on the £719,690 of cancellation value with a customer ID (99.06% of the total).<br>**Customers:** top 10 of 2,445 (0.41%) drive 50% of cancellation value; top 191 (7.8%) drive 80%.<br>**Products:** top 27 of 2,842 (0.95%) drive 50%; top 310 (10.9%) drive 80%.<br>The customer side is about 2.3x more concentrated at the 50% mark. |
| **Overlap** | 78.96% of the top 10 customers' cancellation value falls on the top 27 products, versus a 50.28% baseline (about 1.6x what independence would predict). Concentrated customers and concentrated products are largely the same transactions. |
| **Timing** | Median time from order to cancellation is **12 days**. Of matched cancellations, 19.4% happen the same day, 70.9% within 30 days, and 88.9% within 90 days. |

## Recommendation

**Start with the 10 customers, not the products.** Have the account owners open a conversation, or send a short survey, to learn why these specific customers cancel. Is it something about what is offered, how it is offered, or how it ships?

- **Upside:** the top 10 customers represent about £365K in cancellations, roughly 2.1% of attributable gross sales. If the cause applies across the customer base, the ceiling approaches the full 4.1%.
- **Side benefit:** reaching these customers also covers about 80% of the top products' cancellation value, so no separate product workstream is needed.
- **Cost if it doesn't pan out:** one round of outreach.
- **How to measure:** track results over a 90-day window, which is when most matched cancellations happen.

## Approach

The work is split into four scripts that run in order. Every query has comments explaining what it checks, what it found, and what decision followed.

| File | What it does |
|---|---|
| `00_create_table.sql` | Creates the base table with explicitly declared data types (not inferred by the load wizard) |
| `01_data_validation.sql` | Profiles the raw data across 14 sections and records every cleaning decision before any cleaning happens |
| `02_data_cleaning.sql` | Builds a cleaned, flagged table and a filtered analysis view, with post-build tests that confirm nothing was lost |
| `03_data_analysis.sql` | Answers the four business questions and states the recommendation |

### Data quality decisions

Most of the effort went into validation, because several "obvious" cleaning rules would have quietly removed real sales or kept fake ones:

- **Flag, don't delete.** The cleaned table keeps every original row and adds flag columns (`record_type`, `is_zero_price`, `is_null_customer`, `is_non_product`). Row counts are tested against the source to prove nothing was dropped.
- **Non-products identified individually, not by pattern.** About 99.4% of records use a stock code that follows a five-digit pattern, but some codes that break it are real products (PADS, SP1002, the DCGS range). Postage, fees, bank charges, manual entries, samples, test data, and gift vouchers were each confirmed by inspection and named explicitly.
- **Zero-price junk defined by two conditions, not one.** Treating every zero-price row as junk would have caught 89 real free or promotional sales to known customers. Junk records are identified as zero price **and** no customer ID, and flagged rather than deleted. They carry no value, so they can't affect the value-based findings.
- **Duplicates kept on purpose.** About 34K rows are exact duplicates, but quantities vary within the same invoice in a way that suggests per-unit scanning, not a load error. Removing them would delete units customers actually bought.
- **No invoice-based matching.** Cancellation invoices can't be linked to their original sale by stripping the "C" prefix (for example, sale 581483 was cancelled as C581484). Cancellations were matched to sales on customer, product, and quantity instead.
- **Stock code case normalized after testing.** 173 codes appear in both upper and lower case. I checked every pair to confirm each maps to the same product before merging them.

### Limitations

- **Customer attribution:** 0.94% of cancellation value has no customer ID and is excluded from the concentration, overlap, and timing analysis, so all of those use the same £719,690 base.
- **Timing coverage:** without a line-level key, cancellations were matched to sales by exact quantity. 36% of attributable cancellations matched by count, but those matches cover **78% of cancellation value**, so the timing results reflect the larger cancellations. Partial cancellations and orders placed before the data window can't be matched.
- **Long-tail matches:** cancellations matched more than 90 days out mix genuine late cancellations with coincidental matches to older orders, so the median is reported instead of the mean.
- **Where, not why:** this analysis shows where cancellation value is concentrated. It doesn't explain why those customers cancel, which is what the recommended outreach is for.

## Tools

Snowflake, SQL (CTEs, window functions, self-joins, correlated subqueries, regular expressions)
