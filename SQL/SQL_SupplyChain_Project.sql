--=================================================================
-- PHASE 1: Data Cleaning and Preprocessing
--=================================================================

Create Database SupplyChainDB;
USE SupplyChainDB;
GO

-- Raw staging table, matching the original electronicsSupplyChain.csv columns
CREATE TABLE raw_supply_chain (
    order_id                     VARCHAR(20),
    order_date                   DATE,
    ship_date                    DATE,
    delivery_date                DATE,
    product_type                 VARCHAR(50),
    sku                          VARCHAR(20),
    category                     VARCHAR(50),
    price                        DECIMAL(10,2),
    discount_pct                 DECIMAL(5,2),
    price_after_discount         DECIMAL(10,2),
    number_of_products_sold      INT,
    units_returned                INT,
    return_reason                VARCHAR(100) NULL,
    revenue_generated            DECIMAL(12,2),
    profit                       DECIMAL(12,2),
    customer_satisfaction_score  DECIMAL(6,3),
    customer_demographics        VARCHAR(100),
    sales_channel                VARCHAR(50),
    payment_method                VARCHAR(50),
    region                        VARCHAR(100),
    stock_levels                 INT,
    reorder_point                INT,
    stockout_risk                VARCHAR(10),
    lead_time                    INT,
    shipping_times                INT,
    shipping_costs                DECIMAL(10,2),
    on_time_delivery              VARCHAR(5),
    supplier_name                 VARCHAR(100),
    supplier_reliability_score    DECIMAL(6,3),
    manufacturing_costs           DECIMAL(10,3),
    quality_score                 DECIMAL(5,2),
    defect_rates                  DECIMAL(6,4),
    production_volumes            INT,
    carrier_name                  VARCHAR(100),
    transportation_mode           VARCHAR(50)
);
GO

-- Load the raw CSV (path must point to wherever electronicsSupplyChain.csv sits on the SSMS machine)
BULK INSERT raw_supply_chain
FROM 'C:\SupplyChainData\electronicsSupplyChain.csv'
WITH (
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    CODEPAGE = '65001',
    TABLOCK
);
GO

----------------------------------------------------------------
-- Missing Values
----------------------------------------------------------------
-- Return Reason is NULL for orders that weren't returned -> fill with 'Not Returned'
UPDATE raw_supply_chain
SET return_reason = 'Not Returned'
WHERE return_reason IS NULL;
GO

----------------------------------------------------------------
-- Duplicate Records
----------------------------------------------------------------
-- Check for duplicate rows (should return 0)
SELECT order_id, COUNT(*) AS cnt
FROM raw_supply_chain
GROUP BY order_id
HAVING COUNT(*) > 1;
GO

----------------------------------------------------------------
-- Data Formatting
----------------------------------------------------------------
-- Trim and standardize text columns
UPDATE raw_supply_chain
SET
    product_type            = LTRIM(RTRIM(product_type)),
    category                 = LTRIM(RTRIM(category)),
    return_reason            = LTRIM(RTRIM(return_reason)),
    customer_demographics    = LTRIM(RTRIM(customer_demographics)),
    sales_channel            = LTRIM(RTRIM(sales_channel)),
    payment_method           = LTRIM(RTRIM(payment_method)),
    region                   = LTRIM(RTRIM(region)),
    stockout_risk            = LTRIM(RTRIM(stockout_risk)),
    on_time_delivery         = LTRIM(RTRIM(on_time_delivery)),
    carrier_name             = LTRIM(RTRIM(carrier_name)),
    supplier_name            = LTRIM(RTRIM(supplier_name)),
    transportation_mode      = LTRIM(RTRIM(transportation_mode)),
    sku                      = UPPER(LTRIM(RTRIM(sku)));
GO

-- Standardize carrier name abbreviations
UPDATE raw_supply_chain SET carrier_name = 'DHL'    WHERE carrier_name = 'Dhl';
UPDATE raw_supply_chain SET carrier_name = 'UPS'    WHERE carrier_name = 'Ups';
UPDATE raw_supply_chain SET carrier_name = 'USPS'   WHERE carrier_name = 'Usps';
UPDATE raw_supply_chain SET carrier_name = 'FedEx'  WHERE carrier_name = 'Fedex';
UPDATE raw_supply_chain SET carrier_name = 'OnTrac' WHERE carrier_name = 'Ontrac';
GO

-- is_on_time flag (1 = Yes, 0 = No), mirrors the notebook's derived column
ALTER TABLE raw_supply_chain ADD is_on_time BIT;
GO
UPDATE raw_supply_chain
SET is_on_time = CASE WHEN on_time_delivery = 'Yes' THEN 1 ELSE 0 END;
GO


--=================================================================
-- PHASE 2: Data Normalization
--=================================================================

-- Carrier dimension
CREATE TABLE dim_carriers (
    carrier_id INT PRIMARY KEY,
    carrier_name VARCHAR(100),
    is_on_time DECIMAL(4,2)
);
GO

INSERT INTO dim_carriers (carrier_id, carrier_name, is_on_time)
SELECT
    ROW_NUMBER() OVER (ORDER BY carrier_name) AS carrier_id,
    carrier_name,
    AVG(CAST(is_on_time AS DECIMAL(4,2))) AS is_on_time
FROM raw_supply_chain
GROUP BY carrier_name;
GO

-- Supplier dimension
CREATE TABLE dim_supplier (
    supplier_id INT PRIMARY KEY,
    supplier_name VARCHAR(100),
    avg_reliability_score DECIMAL(4,3),
    avg_quality_score DECIMAL(4,2),
    avg_defect_rate_pct DECIMAL(5,3)
);
GO

INSERT INTO dim_supplier (supplier_id, supplier_name, avg_reliability_score, avg_quality_score, avg_defect_rate_pct)
SELECT
    ROW_NUMBER() OVER (ORDER BY supplier_name) AS supplier_id,
    supplier_name,
    AVG(supplier_reliability_score) AS avg_reliability_score,
    AVG(quality_score) AS avg_quality_score,
    AVG(defect_rates) AS avg_defect_rate_pct
FROM raw_supply_chain
GROUP BY supplier_name;
GO

-- Product dimension
CREATE TABLE dim_products (
    sku VARCHAR(20) PRIMARY KEY,
    product_type VARCHAR(50),
    category VARCHAR(50),
    price DECIMAL(10,2),
    discount_pct DECIMAL(5,2),
    price_after_discount AS CAST(price - (price * discount_pct / 100) AS DECIMAL(10,2)),
    manufacturing_costs DECIMAL(10,3)
);
GO

INSERT INTO dim_products (sku, product_type, category, price, discount_pct, manufacturing_costs)
SELECT DISTINCT
    sku, product_type, category, price, discount_pct, manufacturing_costs
FROM raw_supply_chain;
GO

-- Inventory sub-dimension
CREATE TABLE subdim_inventory (
    sku VARCHAR(20) PRIMARY KEY,
    stock_levels INT,
    reorder_point INT,
    stockout_risk BIT,
    production_volumes INT,
    FOREIGN KEY (sku) REFERENCES dim_products(sku)
);
GO

INSERT INTO subdim_inventory (sku, stock_levels, reorder_point, stockout_risk, production_volumes)
SELECT DISTINCT
    sku,
    stock_levels,
    reorder_point,
    CASE WHEN stockout_risk = 'Yes' THEN 1 ELSE 0 END AS stockout_risk,
    production_volumes
FROM raw_supply_chain;
GO

-- Fact table
CREATE TABLE fact_orders (
    order_id VARCHAR(20) PRIMARY KEY,
    sku VARCHAR(20),
    supplier_id INT,
    carrier_id INT,
    customer_demographics VARCHAR(100),
    region VARCHAR(100),
    sales_channel VARCHAR(50),
    payment_method VARCHAR(50),
    order_date DATE,
    ship_date DATE,
    delivery_date DATE,
    number_of_products_sold INT,
    units_returned INT,
    return_reason VARCHAR(100),
    revenue_generated DECIMAL(12,2),
    profit DECIMAL(12,2),
    customer_satisfaction_score DECIMAL(6,3),
    lead_time INT,
    shipping_times INT,
    shipping_costs DECIMAL(10,2),
    supplier_reliability_score DECIMAL(6,3),
    quality_score DECIMAL(5,2),
    defect_rates DECIMAL(5,2),
    transportation_mode VARCHAR(50),
    on_time_delivery VARCHAR(5),
    total_cost DECIMAL(12,2),
    return_rate AS (
        CASE
            WHEN number_of_products_sold = 0 THEN 0
            ELSE CAST(units_returned AS DECIMAL(10,4)) / number_of_products_sold
        END
    ),
    gross_margin_pct AS (
        CASE
            WHEN revenue_generated = 0 THEN 0
            ELSE CAST((profit * 100.0) / NULLIF(revenue_generated, 0) AS DECIMAL(10,4))
        END
    ),
    FOREIGN KEY (sku) REFERENCES dim_products(sku),
    FOREIGN KEY (supplier_id) REFERENCES dim_supplier(supplier_id),
    FOREIGN KEY (carrier_id) REFERENCES dim_carriers(carrier_id)
);
GO

INSERT INTO fact_orders (
    order_id, sku, supplier_id, carrier_id,
    customer_demographics, region, sales_channel, payment_method,
    order_date, ship_date, delivery_date,
    number_of_products_sold, units_returned, return_reason,
    revenue_generated, profit, customer_satisfaction_score,
    lead_time, shipping_times, shipping_costs,
    supplier_reliability_score, quality_score, defect_rates,
    transportation_mode, on_time_delivery, total_cost
)
SELECT
    r.order_id,
    r.sku,
    sp.supplier_id,
    c.carrier_id,
    r.customer_demographics,
    r.region,
    r.sales_channel,
    r.payment_method,
    r.order_date,
    r.ship_date,
    r.delivery_date,
    r.number_of_products_sold,
    r.units_returned,
    r.return_reason,
    r.revenue_generated,
    r.profit,
    r.customer_satisfaction_score,
    r.lead_time,
    r.shipping_times,
    r.shipping_costs,
    r.supplier_reliability_score,
    r.quality_score,
    r.defect_rates,
    r.transportation_mode,
    r.on_time_delivery,
    (r.manufacturing_costs * r.number_of_products_sold) + r.shipping_costs AS total_cost
FROM raw_supply_chain r
JOIN dim_supplier sp ON r.supplier_name = sp.supplier_name
JOIN dim_carriers c  ON r.carrier_name  = c.carrier_name;
GO

-- Data Model Verification
SELECT 'dim_supplier' AS TableName, COUNT(*) AS RowCount FROM dim_supplier
UNION ALL
SELECT 'dim_carriers', COUNT(*) FROM dim_carriers
UNION ALL
SELECT 'dim_products', COUNT(*) FROM dim_products
UNION ALL
SELECT 'subdim_inventory', COUNT(*) FROM subdim_inventory
UNION ALL
SELECT 'fact_orders', COUNT(*) FROM fact_orders;
GO


--=================================================================
-- PHASE 3: Analysis Questions
--=================================================================

--Q1. What is the overall financial performance summary, including total revenue, total profit, overall gross margin percentage, and average customer satisfaction score?

SELECT
    SUM(revenue_generated) AS Total_Revenue,
    SUM(profit) AS Total_Profit,
    SUM(profit) * 100.0 / SUM(revenue_generated) AS Gross_Margin,
    AVG(customer_satisfaction_score) AS Avg_Satisfaction
FROM fact_orders;

-- Q2. How does monthly revenue trend across 2022-2024, and which month records the highest month-over-month growth rate within each year?

WITH MonthlyRevenue AS
(
    SELECT
        YEAR(order_date) AS Year,
        MONTH(order_date) AS Month,
        SUM(revenue_generated) AS Total_Revenue
    FROM fact_orders
    GROUP BY YEAR(order_date), MONTH(order_date)
)

SELECT *,
       LAG(Total_Revenue) OVER(PARTITION BY Year ORDER BY Month) AS Previous_Month
FROM MonthlyRevenue
ORDER BY Year, Month;


-- Q3. How is total revenue distributed across Q1-Q4, and does this seasonal pattern remain consistent across 2022, 2023, and 2024?

SELECT
    YEAR(order_date) AS Year,
    DATEPART(QUARTER, order_date) AS Quarter,
    SUM(revenue_generated) AS Total_Revenue
FROM fact_orders
GROUP BY YEAR(order_date), DATEPART(QUARTER, order_date)
ORDER BY Year, Quarter;


-- Q4. Which customer demographic segment contributes the most to total revenue and profit, and how does average satisfaction score compare across segments?

SELECT
    customer_demographics,
    SUM(revenue_generated) AS Total_Revenue,
    SUM(profit) AS Total_Profit,
    AVG(customer_satisfaction_score) AS Avg_Satisfaction
FROM fact_orders
GROUP BY customer_demographics
ORDER BY Total_Revenue DESC;


-- Q5. How does total revenue, average selling price, average discount, and total units sold vary across product categories?

SELECT
    p.category,
    SUM(f.revenue_generated) AS Total_Revenue,
    AVG(p.price_after_discount) AS Avg_Selling_Price,
    AVG(p.discount_pct) AS Avg_Discount,
    SUM(f.number_of_products_sold) AS Total_Units_Sold
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
GROUP BY p.category
ORDER BY Total_Revenue DESC;


-- Q6. Which sales channel achieves the highest average gross margin percentage, and how does total revenue volume compare across channels?

SELECT
    sales_channel,
    SUM(revenue_generated) AS Total_Revenue,
    AVG((profit * 100.0) / NULLIF(revenue_generated, 0)) AS Avg_Gross_Margin
FROM fact_orders
GROUP BY sales_channel
ORDER BY Avg_Gross_Margin DESC;


-- Q7. Which geographic region contributes the highest share of total profit, and how does its revenue and average gross margin compare to other regions?

SELECT
    region,
    SUM(revenue_generated) AS Total_Revenue,
    SUM(profit) AS Total_Profit,
    AVG((profit * 100.0) / NULLIF(revenue_generated, 0)) AS Avg_Gross_Margin
FROM fact_orders
GROUP BY region
ORDER BY Total_Profit DESC;


-- Q8. What is the average discount percentage applied per product category, and how does it relate to the average price and profit margin within each category?

SELECT
    p.category,
    AVG(p.discount_pct) AS Avg_Discount,
    AVG(p.price_after_discount) AS Avg_Price,
    AVG((f.profit * 100.0) / NULLIF(f.revenue_generated, 0)) AS Avg_Profit_Margin
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
GROUP BY p.category
ORDER BY Avg_Discount DESC;

-- Q9. Which product type has the highest average manufacturing cost relative to its selling price, and how does this cost-to-price ratio affect profitability?

SELECT
    product_type,
    AVG(manufacturing_costs) AS Avg_Manufacturing_Cost,
    AVG(price_after_discount) AS Avg_Selling_Price,
    AVG((manufacturing_costs * 100.0) / NULLIF(price_after_discount,0)) AS Cost_Price_Ratio
FROM dim_products
GROUP BY product_type
ORDER BY Cost_Price_Ratio DESC;


-- Q10. Which payment method is associated with the highest average revenue per order, and which payment method accounts for the highest total order volume?

SELECT
    payment_method,
    AVG(revenue_generated) AS Avg_Revenue_Per_Order,
    COUNT(order_id) AS Total_Orders
FROM fact_orders
GROUP BY payment_method
ORDER BY Avg_Revenue_Per_Order DESC;


-- Q11. Which suppliers demonstrate the best overall performance based on reliability score, quality score, defect rate, average lead time, and total profit contribution?

SELECT
    s.supplier_name,
    AVG(f.supplier_reliability_score) AS Reliability,
    AVG(f.quality_score) AS Quality,
    AVG(f.defect_rates) AS Defect_Rate,
    AVG(f.lead_time) AS Avg_Lead_Time,
    SUM(f.profit) AS Total_Profit
FROM fact_orders f
JOIN dim_supplier s
ON f.supplier_id = s.supplier_id
GROUP BY s.supplier_name
ORDER BY Total_Profit DESC;


-- Q12. What is the total revenue lost due to returned units per supplier, and is there a noticeable correlation with each supplier's average defect rate?

SELECT
    s.supplier_name,
    SUM((revenue_generated / NULLIF(number_of_products_sold,0)) * units_returned) AS Revenue_Lost,
    AVG(defect_rates) AS Avg_Defect_Rate
FROM fact_orders f
JOIN dim_supplier s
ON f.supplier_id = s.supplier_id
GROUP BY s.supplier_name
ORDER BY Revenue_Lost DESC;


-- Q13. What is the on-time delivery rate (%) for each carrier, and which carrier offers the best balance between delivery reliability and average shipping cost?

SELECT
    c.carrier_name,
    AVG(CASE WHEN f.on_time_delivery = 'Yes' THEN 1.0 ELSE 0.0 END) * 100 AS On_Time_Rate_Pct,
    AVG(f.shipping_costs) AS Avg_Shipping_Cost
FROM fact_orders f
JOIN dim_carriers c
ON f.carrier_id = c.carrier_id
GROUP BY c.carrier_name
ORDER BY On_Time_Rate_Pct DESC;


-- Q14. What is the average transit time per transportation mode - and does air freight show a longer average transit time than sea freight in this dataset?

SELECT
    transportation_mode,
    AVG(shipping_times) AS Avg_Transit_Time
FROM fact_orders
GROUP BY transportation_mode;


-- Q15. What is the average shipping cost per carrier, and how does cost rank compare to each carrier's on-time delivery performance?

SELECT
    c.carrier_name,
    AVG(f.shipping_costs) AS Avg_Shipping_Cost,
    AVG(CASE WHEN f.on_time_delivery = 'Yes' THEN 1.0 ELSE 0.0 END) * 100 AS On_Time_Rate_Pct
FROM fact_orders f
JOIN dim_carriers c
ON f.carrier_id = c.carrier_id
GROUP BY c.carrier_name
ORDER BY Avg_Shipping_Cost DESC;


-- Q16. How does average customer satisfaction score differ between on-time and late deliveries, and what is the magnitude of this impact?

SELECT
    CASE
        WHEN on_time_delivery = 'Yes' THEN 'On Time'
        ELSE 'Late'
    END AS Delivery_Status,
    AVG(customer_satisfaction_score) AS Avg_Satisfaction
FROM fact_orders
GROUP BY
    CASE
        WHEN on_time_delivery = 'Yes' THEN 'On Time'
        ELSE 'Late'
    END;

-- Q17. Which region incurs the highest total shipping costs, and how does the average shipping cost per order compare across regions?

SELECT
    region,
    SUM(shipping_costs) AS Total_Shipping_Cost,
    AVG(shipping_costs) AS Avg_Shipping_Cost
FROM fact_orders
GROUP BY region
ORDER BY Total_Shipping_Cost DESC;


-- Q18. Which product category has the highest return rate (units returned divided by units sold), and what is the most frequent return reason associated with it?

SELECT
    p.category,
    SUM(f.units_returned) * 1.0 / SUM(f.number_of_products_sold) AS Return_Rate,
    f.return_reason,
    COUNT(*) AS Total_Returns
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
WHERE f.units_returned > 0
GROUP BY p.category, f.return_reason
ORDER BY Return_Rate DESC, Total_Returns DESC;


-- Q19. What is the most common return reason across all returned orders, and how is it distributed across product categories?

SELECT
    p.category,
    f.return_reason,
    COUNT(*) AS Total_Returns
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
WHERE f.units_returned > 0
GROUP BY p.category, f.return_reason
ORDER BY Total_Returns DESC;


-- Q20. How many SKUs are currently flagged as stockout risk, and which product types are most affected?

SELECT
    p.product_type,
    COUNT(*) AS Stockout_SKUs
FROM subdim_inventory s
JOIN dim_products p
ON s.sku = p.sku
WHERE s.stockout_risk = 1
GROUP BY p.product_type
ORDER BY Stockout_SKUs DESC;


-- Q21. Which product type has the highest average defect rate, and does it also record the highest return rate?

SELECT
    p.product_type,
    AVG(f.defect_rates) AS Avg_Defect_Rate,
    SUM(f.units_returned) * 1.0 / SUM(f.number_of_products_sold) AS Return_Rate
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
GROUP BY p.product_type
ORDER BY Avg_Defect_Rate DESC;


-- Q22. Which product type generates the highest total number of units sold, and what is its share of total sales volume?

SELECT
    p.product_type,
    SUM(f.number_of_products_sold) AS Total_Units_Sold,
    SUM(f.number_of_products_sold) * 100.0 / (SELECT SUM(number_of_products_sold) FROM fact_orders) AS Sales_Share
FROM fact_orders f
JOIN dim_products p
ON f.sku = p.sku
GROUP BY p.product_type
ORDER BY Total_Units_Sold DESC;
