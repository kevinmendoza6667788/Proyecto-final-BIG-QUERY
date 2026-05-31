
-- ============================================================================
-- CURSO BIGQUERY (GOOGLE SQL) - PROYECTO FINAL
-- Alumno: Franklin Kevin Gomez Mendoza
-- Caso de Uso: Analítica para E-commerce (Ventas, Rentabilidad y Tráfico)
-- ============================================================================

-- ============================================================================
-- 01_RAW: EXTRACCIÓN Y COPIA DE FUENTES
-- ============================================================================

-- Tabla 1: Usuarios (Datos demográficos y adquisición)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_users` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.users`;

-- Tabla 2: Órdenes (Cabeceras de transacción y estados)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_orders` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.orders`;


-- Tabla 3: Ítems de Órdenes (Detalle de productos vendidos y precios)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_order_items` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.order_items`;

-- Tabla 4: Productos (Catálogo maestro)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_products` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.products`;

-- Tabla 5: Inventario (Para obtener el COSTO y calcular la rentabilidad)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_inventory_items` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.inventory_items`;

-- Tabla 6: Eventos (Navegación web para el Funnel de Conversión)
CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.raw_events` AS
SELECT * FROM `bigquery-public-data.thelook_ecommerce.events`;

-- ============================================================================
-- 02_STG_VIEWS: LIMPIEZA, TRADUCCIÓN Y JOINS
-- ============================================================================

-- VISTA 1: Usuarios Hispanizados
-- Limpieza de géneros y selección de columnas clave.
CREATE OR REPLACE VIEW `datasciencepedan6.ecommerce_analytics_pr.stg_usuarios` AS
SELECT 
    id AS id_usuario,
    first_name AS nombre,
    last_name AS apellido,
    age AS edad,
    -- Estandarización y traducción de género
    CASE 
        WHEN gender = 'M' THEN 'Masculino' 
        WHEN gender = 'F' THEN 'Femenino' 
        ELSE gender 
    END AS genero,
    country AS pais,
    traffic_source AS fuente_adquisicion,
    DATE(created_at) AS fecha_registro
FROM `datasciencepedan6.ecommerce_analytics_pr.raw_users`;

-- VISTA 2: Ventas, Productos y Rentabilidad 
-- INNER JOIN y LEFT JOIN. 
-- Además calculamos el Margen de Ganancia.
CREATE OR REPLACE VIEW `datasciencepedan6.ecommerce_analytics_pr.stg_ventas_completas` AS
SELECT 
    oi.id AS id_detalle,
    o.order_id AS id_orden,
    o.user_id AS id_usuario,
    DATE(o.created_at) AS fecha_orden,
    FORMAT_DATE('%Y-%m', o.created_at) AS mes_orden,
    -- Traducción de estados de la orden
    CASE o.status
        WHEN 'Shipped' THEN 'Enviado'
        WHEN 'Complete' THEN 'Completado'
        WHEN 'Processing' THEN 'En Proceso'
        WHEN 'Cancelled' THEN 'Cancelado'
        WHEN 'Returned' THEN 'Devuelto'
        ELSE o.status
    END AS estado_orden,
    p.category AS categoria_producto,
    p.department AS departamento_producto,
    oi.sale_price AS precio_venta,
    ii.cost AS costo_producto,
    -- Creación de métrica de negocio clave:
    (oi.sale_price - ii.cost) AS margen_ganancia
FROM `datasciencepedan6.ecommerce_analytics_pr.raw_order_items` oi
-- INNER JOIN: Solo queremos ítems que pertenezcan a una orden válida
INNER JOIN `datasciencepedan6.ecommerce_analytics_pr.raw_orders` o
    ON oi.order_id = o.order_id
-- INNER JOIN: Solo queremos ítems que tengan un producto asociado en el catálogo
INNER JOIN `datasciencepedan6.ecommerce_analytics_pr.raw_products` p
    ON oi.product_id = p.id
-- LEFT JOIN: Traemos el costo del inventario (si un ítem no tiene inventario mapeado, 
-- no queremos perder la venta, solo su costo quedará en null)
LEFT JOIN `datasciencepedan6.ecommerce_analytics_pr.raw_inventory_items` ii
    ON oi.inventory_item_id = ii.id;

-- VISTA 3: Tráfico Web y Embudo (Funnel)
-- Clasificamos los eventos numéricamente para hacer el embudo en Looker Studio.
CREATE OR REPLACE VIEW `datasciencepedan6.ecommerce_analytics_pr.stg_trafico_web` AS
SELECT 
    id AS id_evento,
    user_id AS id_usuario,
    session_id AS id_sesion,
    DATE(created_at) AS fecha_evento,
    FORMAT_DATE('%Y-%m', created_at) AS mes_evento,
    traffic_source AS fuente_trafico,
    -- Clasificación para ordenar el embudo de conversión lógicamente
    CASE event_type
        WHEN 'home' THEN '1_Inicio'
        WHEN 'department' THEN '2_Departamento'
        WHEN 'product' THEN '3_Producto'
        WHEN 'cart' THEN '4_Carrito'
        WHEN 'purchase' THEN '5_Compra'
        WHEN 'cancel' THEN '6_Cancelación'
        ELSE event_type
    END AS tipo_evento_funnel
FROM `datasciencepedan6.ecommerce_analytics_pr.raw_events`;


-- ============================================================================
-- 03_MARTS: TABLAS ANALÍTICAS FINALES Y ESTRUCTURAS COMPLEJAS
-- ============================================================================

-- MART 1: Rendimiento Comercial y Rentabilidad Mensual por País
-- Uso de función analítica LAG() para comparar vs mes anterior.

CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.mart_ventas_rentabilidad_mes` AS
WITH metricas_base AS (
    SELECT 
        v.mes_orden,
        u.pais,
        COUNT(DISTINCT v.id_orden) AS total_ordenes,
        COUNT(DISTINCT v.id_usuario) AS total_clientes,
        ROUND(SUM(v.precio_venta), 2) AS ingresos_totales,
        ROUND(SUM(v.costo_producto), 2) AS costo_total,
        ROUND(SUM(v.margen_ganancia), 2) AS margen_total
    FROM `datasciencepedan6.ecommerce_analytics_pr.stg_ventas_completas` v
    LEFT JOIN `datasciencepedan6.ecommerce_analytics_pr.stg_usuarios` u 
        ON v.id_usuario = u.id_usuario
    WHERE v.estado_orden NOT IN ('Cancelado', 'Devuelto') -- Solo ventas efectivas
    GROUP BY 1, 2
)
SELECT 
    *,
    -- Calculamos el porcentaje de rentabilidad (% de Margen)
    ROUND(SAFE_DIVIDE(margen_total, ingresos_totales) * 100, 2) AS margen_porcentaje,
    -- Función LAG: Traemos los ingresos del mes anterior para el mismo país
    LAG(ingresos_totales) OVER(PARTITION BY pais ORDER BY mes_orden) AS ingresos_mes_anterior,
    -- Cálculo del crecimiento MoM (Month-over-Month)
    ROUND(SAFE_DIVIDE(
        ingresos_totales - LAG(ingresos_totales) OVER(PARTITION BY pais ORDER BY mes_orden),
        LAG(ingresos_totales) OVER(PARTITION BY pais ORDER BY mes_orden)
    ) * 100, 2) AS crecimiento_ingresos_pct
FROM metricas_base;


-- MART 2: Embudo de Conversión Web 
-- Agregamos el tráfico web para analizar caídas en Looker Studio.

CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.mart_embudo_conversion_web` AS
SELECT 
    mes_evento,
    fuente_trafico,
    tipo_evento_funnel,
    COUNT(DISTINCT id_sesion) AS total_sesiones,
    COUNT(DISTINCT id_usuario) AS usuarios_unicos
FROM `datasciencepedan6.ecommerce_analytics_pr.stg_trafico_web`
GROUP BY 1, 2, 3;


    -- MART 3: Top Productos por País (Estructura Anidada)
    -- Uso de ARRAY_AGG(STRUCT(...)) y función RANK().

    CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.mart_top_productos_pais` AS
    WITH rank_productos AS (
        SELECT 
            u.pais,
            v.categoria_producto,
            ROUND(SUM(v.margen_ganancia), 2) AS margen_generado,
            -- Asignamos un ranking basado en el margen de ganancia
            RANK() OVER(PARTITION BY u.pais ORDER BY SUM(v.margen_ganancia) DESC) AS ranking
        FROM `datasciencepedan6.ecommerce_analytics_pr.stg_ventas_completas` v
        JOIN `datasciencepedan6.ecommerce_analytics_pr.stg_usuarios` u 
            ON v.id_usuario = u.id_usuario
        WHERE v.estado_orden NOT IN ('Cancelado', 'Devuelto')
        GROUP BY 1, 2
    )
    SELECT 
        pais,
        -- Empaquetamos el top 5 en un Arreglo de Estructuras (ARRAY/STRUCT)
        ARRAY_AGG(
            STRUCT(ranking, categoria_producto, margen_generado) 
            ORDER BY ranking LIMIT 5
        ) AS top_5_productos_rentables
    FROM rank_productos
    WHERE ranking <= 5
    GROUP BY 1;


-- MART 4: Top Productos
-- Demostración explícita del uso de UNNEST().

CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.mart_top_productos_plano` AS
SELECT 
    t.pais,
    productos.ranking,
    productos.categoria_producto,
    productos.margen_generado
FROM `datasciencepedan6.ecommerce_analytics_pr.mart_top_productos_pais` t,
UNNEST(t.top_5_productos_rentables) AS productos;


-- ============================================================================
-- 04_SCRIPT/PROCEDURE: AUTOMATIZACIÓN CON DECLARE
-- ============================================================================

-- Crear un Stored Procedure parametrizable usando DECLARE 
-- para aislar y guardar los datos de un mes en particular.

CREATE OR REPLACE PROCEDURE `datasciencepedan6.ecommerce_analytics_pr.sp_resumen_mensual`(mes_parametro STRING)
BEGIN
    --  Declaración de variables (DECLARE)
    DECLARE var_mes_analisis STRING;
    DECLARE var_filas_afectadas INT64;

    -- Lógica de control de fechas: Si el usuario no pasa un mes, usamos el mes actual.
    IF mes_parametro IS NULL OR mes_parametro = '' THEN
        SET var_mes_analisis = FORMAT_DATE('%Y-%m', CURRENT_DATE());
    ELSE
        SET var_mes_analisis = mes_parametro;
    END IF;

    -- Ejecución de carga de forma repetible: 
    -- Creamos una tabla temporal o de "snapshot" solo para ese mes.
    -- Usamos EXECUTE IMMEDIATE porque estamos inyectando una variable dinámica en el nombre del mes.
    EXECUTE IMMEDIATE FORMAT("""
        CREATE OR REPLACE TABLE `datasciencepedan6.ecommerce_analytics_pr.mart_snapshot_mes_seleccionado` AS
        SELECT 
            v.mes_orden,
            v.estado_orden,
            COUNT(DISTINCT v.id_orden) AS total_ordenes,
            ROUND(SUM(v.margen_ganancia), 2) AS margen_total_generado
        FROM `datasciencepedan6.ecommerce_analytics_pr.stg_ventas_completas` v
        WHERE v.mes_orden = '%s'
        GROUP BY 1, 2;
    """, var_mes_analisis);

    --  Capturamos cuántas filas se crearon en la tabla usando una variable de sistema de BQ
    SET var_filas_afectadas = @@row_count;

    -- Imprimimos un mensaje de éxito para que el usuario sepa qué pasó
    SELECT FORMAT('Éxito. Se calculó el periodo %s. Filas generadas en el resumen: %d', var_mes_analisis, var_filas_afectadas) AS resultado_ejecucion;

END;




