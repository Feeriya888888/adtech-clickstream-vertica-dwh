-- ============================================================================
-- 01_ddl_projections_encoding.sql
-- Проектирование колоночной схемы AdTech Clickstream в Vertica MPP
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS adtech;

-- 1. Справочник рекламных кампаний (Несегментированная проекция: реплицируется на все узлы)
CREATE TABLE IF NOT EXISTS adtech.dim_campaigns (
    campaign_id     INT NOT NULL PRIMARY KEY,
    advertiser_name VARCHAR(120) ENCODING ZSTD_FAST_COMP,
    vertical        VARCHAR(50)  ENCODING RLE,
    daily_budget_usd NUMERIC(12, 2) ENCODING DELTARANGE_COMP,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) UNSEGMENTED ALL NODES;

-- 2. Основная таблица потока событий (Fact Table)
-- Обратите внимание: в Vertica нет индексов. Физическая сортировка и сжатие задаются в PROJECTION.
CREATE TABLE IF NOT EXISTS adtech.fct_ad_events (
    event_id        VARCHAR(36)  NOT NULL,
    event_ts        TIMESTAMP    NOT NULL,
    user_id         BIGINT       NOT NULL,
    campaign_id     INT          NOT NULL,
    event_type      VARCHAR(16)  NOT NULL, -- 'impression', 'click', 'conversion'
    device_type     VARCHAR(16)  NOT NULL, -- 'mobile', 'desktop', 'tablet'
    country_code    CHAR(2)      NOT NULL,
    bid_price_usd   NUMERIC(10, 6) NOT NULL,
    revenue_usd     NUMERIC(10, 4) DEFAULT 0
)
PARTITION BY (event_ts::DATE)
GROUP BY (calendar_hierarchy_day(event_ts::DATE, 3, 2)); -- Иерархическая группировка партиций (защита от ROS Pushback)

-- 3. Суперпроекция (Superprojection) с оптимальным колоночным кодированием
-- Оптимизирована для user-level сессионизации и атрибуции (сортировка по user_id, event_ts)
CREATE PROJECTION adtech.fct_ad_events_super (
    event_id        ENCODING ZSTD_FAST_COMP,
    event_ts        ENCODING DELTARANGE_COMP,
    user_id         ENCODING DELTARANGE_COMP,
    campaign_id     ENCODING DELTARANGE_COMP,
    event_type      ENCODING RLE,
    device_type     ENCODING RLE,
    country_code    ENCODING RLE,
    bid_price_usd   ENCODING GCDDELTA,
    revenue_usd     ENCODING ZSTD_FAST_COMP
)
AS SELECT 
    event_id, event_ts, user_id, campaign_id, event_type, device_type, country_code, bid_price_usd, revenue_usd
FROM adtech.fct_ad_events
ORDER BY user_id, event_ts, event_type
SEGMENTED BY HASH(user_id) ALL NODES KSAFE 1;

-- 4. Специализированная Query-Specific проекция для дашбордов по кампаниям и странам
-- Позволяет считать CTR/CR по кампаниям без пересортировки и пересылки данных по сети (GROUPBY PIPELINED)
CREATE PROJECTION adtech.fct_ad_events_by_campaign (
    campaign_id     ENCODING RLE,
    country_code    ENCODING RLE,
    event_type      ENCODING RLE,
    event_ts        ENCODING DELTARANGE_COMP,
    user_id         ENCODING ZSTD_FAST_COMP,
    bid_price_usd   ENCODING GCDDELTA,
    revenue_usd     ENCODING ZSTD_FAST_COMP
)
AS SELECT 
    campaign_id, country_code, event_type, event_ts, user_id, bid_price_usd, revenue_usd
FROM adtech.fct_ad_events
ORDER BY campaign_id, country_code, event_type, event_ts
SEGMENTED BY HASH(campaign_id) ALL NODES KSAFE 1;

-- 5. Живая агрегированная проекция (Live Aggregate Projection)
-- Автоматически обновляется при каждой вставке данных (аналог инкрементальной материализованной витрины)
CREATE PROJECTION adtech.lap_campaign_hourly_stats AS
SELECT 
    campaign_id,
    DATE_TRUNC('hour', event_ts) AS event_hour,
    country_code,
    COUNT(*) AS total_events,
    SUM(CASE WHEN event_type = 'impression' THEN 1 ELSE 0 END) AS impressions,
    SUM(CASE WHEN event_type = 'click' THEN 1 ELSE 0 END) AS clicks,
    SUM(CASE WHEN event_type = 'conversion' THEN 1 ELSE 0 END) AS conversions,
    SUM(bid_price_usd) AS total_spend_usd,
    SUM(revenue_usd) AS total_revenue_usd
FROM adtech.fct_ad_events
GROUP BY campaign_id, DATE_TRUNC('hour', event_ts), country_code;
