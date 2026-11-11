-- ============================================================================
-- 02_etl_copy_and_maintenance.sql
-- Высокоскоростная загрузка (DIRECT), генерация данных и управление ROS/WOS
-- ============================================================================

-- 1. Наполнение справочника кампаний
INSERT /*+ DIRECT */ INTO adtech.dim_campaigns (campaign_id, advertiser_name, vertical, daily_budget_usd)
SELECT 
    id,
    'Advertiser_' || (id % 50),
    CASE (id % 4)
        WHEN 0 THEN 'E-Commerce'
        WHEN 1 THEN 'FinTech'
        WHEN 2 THEN 'Gaming'
        ELSE 'Travel'
    END,
    (1000 + (id % 9000))::NUMERIC(12, 2)
FROM (
    SELECT ROW_NUMBER() OVER() AS id 
    FROM tables CROSS JOIN columns LIMIT 500
) t;

-- 2. Генерация 500 000 событий clickstream и прямая запись в ROS минуя WOS (hint /*+ DIRECT */)
-- В production здесь используется команда: COPY adtech.fct_ad_events FROM 's3://bucket/events/*.parquet' PARQUET DIRECT;
INSERT /*+ DIRECT */ INTO adtech.fct_ad_events (
    event_id, event_ts, user_id, campaign_id, event_type, device_type, country_code, bid_price_usd, revenue_usd
)
WITH seq AS (
    SELECT ROW_NUMBER() OVER() AS rn
    FROM columns a CROSS JOIN columns b
    LIMIT 500000
)
SELECT 
    UUID_GENERATE()::VARCHAR(36) AS event_id,
    TIMESTAMP '2026-11-01 00:00:00' + (rn % 864000) * INTERVAL '1 second' AS event_ts,
    100000 + (rn % 45000) AS user_id,
    1 + (rn % 500) AS campaign_id,
    CASE 
        WHEN rn % 25 = 0 THEN 'conversion'
        WHEN rn % 5  = 0 THEN 'click'
        ELSE 'impression'
    END AS event_type,
    CASE (rn % 3)
        WHEN 0 THEN 'mobile'
        WHEN 1 THEN 'desktop'
        ELSE 'tablet'
    END AS device_type,
    CASE (rn % 5)
        WHEN 0 THEN 'US'
        WHEN 1 THEN 'DE'
        WHEN 2 THEN 'GB'
        WHEN 3 THEN 'RU'
        ELSE 'BR'
    END AS country_code,
    ROUND((0.001 + (rn % 50) * 0.0005)::NUMERIC, 6) AS bid_price_usd,
    CASE WHEN rn % 25 = 0 THEN ROUND((15.0 + (rn % 120))::NUMERIC, 4) ELSE 0 END AS revenue_usd
FROM seq;

COMMIT;

-- 3. Принудительное слияние ROS-контейнеров (Tuple Mover Mergeout) и сбор статистики для оптимизатора
SELECT DO_TM_TASK('mergeout', 'adtech.fct_ad_events');
SELECT ANALYZE_STATISTICS('adtech.fct_ad_events');
SELECT ANALYZE_STATISTICS('adtech.dim_campaigns');

-- 4. Аудит сжатия колонок и количества ROS-контейнеров
SELECT 
    projection_name,
    anchor_table_name,
    SUM(ros_count) AS total_ros_containers,
    SUM(total_row_count) AS total_rows,
    ROUND(SUM(used_bytes) / 1024.0 / 1024.0, 2) AS size_mb
FROM v_monitor.storage_containers
WHERE schema_name = 'adtech'
GROUP BY projection_name, anchor_table_name
ORDER BY size_mb DESC;
