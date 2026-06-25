-- ========================================================
-- Capa Backend Google Cloud SQL (PostgreSQL) - Catástrofe Caracas
-- ========================================================

-- 1. EXTENSIONES REQUERIDAS
-- Habilita búsquedas difusas para nombres de desaparecidos
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2. ENUMS DE APLICACIÓN
CREATE TYPE incident_type AS ENUM ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros');
CREATE TYPE urgency_level AS ENUM ('critico', 'alto', 'moderado');

-- 3. TABLA PRINCIPAL: reports
CREATE TABLE public.reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type incident_type NOT NULL,
    urgency urgency_level NOT NULL,
    description TEXT NOT NULL,
    location_text TEXT NOT NULL, -- GPS inestable; la descripción física de la ubicación es obligatoria
    lat DOUBLE PRECISION,        -- Coordenada opcional
    lng DOUBLE PRECISION,        -- Coordenada opcional
    contact_info TEXT,           -- Permite reportes anónimos si se omite
    is_resolved BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT timezone('utc'::text, now())
);

-- 4. TABLA SECUNDARIA: missing_persons
CREATE TABLE public.missing_persons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    physical_description TEXT,
    last_seen_location TEXT
);

-- 5. ÍNDICES DE OPTIMIZACIÓN (Esenciales para baja latencia en redes 2G)
-- Índice compuesto para el feed principal de incidentes activos y prioritarios
CREATE INDEX idx_reports_active_feed ON public.reports (is_resolved, urgency, created_at DESC);

-- Índice por tipo de incidente
CREATE INDEX idx_reports_type ON public.reports (type);

-- Índice de clave foránea para optimizar JOINs inmediatos
CREATE INDEX idx_missing_persons_report_id ON public.missing_persons (report_id);

-- Índice GIN (Fuzzy Search) para nombres de desaparecidos con pg_trgm
CREATE INDEX idx_missing_persons_name_trgm ON public.missing_persons USING gin (full_name gin_trgm_ops);

-- ========================================================
-- SEGURIDAD A NIVEL DE FILAS (RLS) EN CLOUD SQL
-- ========================================================
-- En Cloud SQL PostgreSQL, al no contar con el middleware automático de Supabase,
-- la seguridad se refuerza utilizando variables de sesión de aplicación.
-- El backend (Cloud Run) ejecutará: "SET LOCAL app.role = 'authenticated'" para rescatistas.

-- Habilitar RLS en las tablas
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons ENABLE ROW LEVEL SECURITY;

-- Aplicar RLS a todas las operaciones para asegurar que afecten a usuarios de aplicación
ALTER TABLE public.reports FORCE ROW LEVEL SECURITY;
ALTER TABLE public.missing_persons FORCE ROW LEVEL SECURITY;

-- -- POLÍTICAS PARA: reports -- --

-- SELECT: Acceso público (cualquier rol de sesión o anónimo)
CREATE POLICY "Permitir select público en reports" 
ON public.reports 
FOR SELECT 
USING (true);

-- INSERT: Acceso público (permite enviar reportes sin estar logueado)
CREATE POLICY "Permitir insert público en reports" 
ON public.reports 
FOR INSERT 
WITH CHECK (true);

-- UPDATE: Solo usuarios de la app con rol 'authenticated' (rescatistas/admin)
CREATE POLICY "Permitir update a rescatistas autenticados" 
ON public.reports 
FOR UPDATE 
USING (current_setting('app.role', true) = 'authenticated')
WITH CHECK (current_setting('app.role', true) = 'authenticated');

-- DELETE: Solo usuarios de la app con rol 'authenticated' (rescatistas/admin)
CREATE POLICY "Permitir delete a rescatistas autenticados" 
ON public.reports 
FOR DELETE 
USING (current_setting('app.role', true) = 'authenticated');


-- -- POLÍTICAS PARA: missing_persons -- --

-- SELECT: Acceso público para búsqueda de desaparecidos
CREATE POLICY "Permitir select público en missing_persons" 
ON public.missing_persons 
FOR SELECT 
USING (true);

-- INSERT: Acceso público
CREATE POLICY "Permitir insert público en missing_persons" 
ON public.missing_persons 
FOR INSERT 
WITH CHECK (true);

-- UPDATE: Solo rescatistas autenticados
CREATE POLICY "Permitir update en missing_persons a rescatistas" 
ON public.missing_persons 
FOR UPDATE 
USING (current_setting('app.role', true) = 'authenticated')
WITH CHECK (current_setting('app.role', true) = 'authenticated');

-- DELETE: Solo rescatistas autenticados
CREATE POLICY "Permitir delete en missing_persons a rescatistas" 
ON public.missing_persons 
FOR DELETE 
USING (current_setting('app.role', true) = 'authenticated');

-- ========================================================
-- ROL Y PERMISOS DE CONEXIÓN PARA EL BACKEND (Cloud Run)
-- ========================================================

-- Nota: Ejecutar este bloque con privilegios de superusuario (postgres) al configurar Cloud SQL.
-- CREATE ROLE app_user WITH LOGIN PASSWORD 'CAMBIA_ESTO_POR_UNA_CLAVE_SEGURA';

-- Otorgar permisos al rol de la aplicación en el esquema public
GRANT USAGE ON SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- ========================================================
-- RPC ATÓMICO: PROCESAMIENTO DE UN SOLO PAYLOAD (TRANSACCIÓN ÚNICA)
-- ========================================================

/**
 * Inserta un reporte de emergencia y, si es necesario, los datos del desaparecido
 * en una sola llamada de red y dentro de una única transacción de base de datos.
 * Esto evita inserciones huérfanas en conexiones móviles 2G inestables.
 *
 * Se ejecuta bajo SECURITY DEFINER para asegurar la consistencia y el control transaccional.
 */
CREATE OR REPLACE FUNCTION public.submit_emergency_report(payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER -- Ejecuta con permisos del dueño para eludir RLS en la inserción atómica inicial
SET search_path = public
AS $$
DECLARE
    v_report_id UUID;
    v_type TEXT;
    v_urgency TEXT;
    v_description TEXT;
    v_location_text TEXT;
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_contact_info TEXT;
    v_missing_person JSONB;
    v_mp_name TEXT;
    v_mp_description TEXT;
    v_mp_last_seen TEXT;
BEGIN
    -- 1. Extracción de variables
    v_type := payload->>'type';
    v_urgency := payload->>'urgency';
    v_description := payload->>'description';
    v_location_text := payload->>'location_text';
    v_lat := (payload->>'lat')::DOUBLE PRECISION;
    v_lng := (payload->>'lng')::DOUBLE PRECISION;
    v_contact_info := payload->>'contact_info';
    v_missing_person := payload->'missing_person';

    -- 2. Validaciones obligatorias de campos
    IF v_type IS NULL OR v_type = '' THEN
        RAISE EXCEPTION 'El campo "type" es requerido.';
    END IF;
    IF v_urgency IS NULL OR v_urgency = '' THEN
        RAISE EXCEPTION 'El campo "urgency" es requerido.';
    END IF;
    IF v_description IS NULL OR v_description = '' THEN
        RAISE EXCEPTION 'El campo "description" es requerido.';
    END IF;
    IF v_location_text IS NULL OR v_location_text = '' THEN
        RAISE EXCEPTION 'El campo "location_text" es requerido.';
    END IF;

    -- Validaciones de integridad para enums
    IF NOT (v_type IN ('desaparecido', 'emergencia_medica', 'rescate_estructural', 'suministros')) THEN
        RAISE EXCEPTION 'Tipo de incidente inválido: %', v_type;
    END IF;

    IF NOT (v_urgency IN ('critico', 'alto', 'moderado')) THEN
        RAISE EXCEPTION 'Nivel de urgencia inválido: %', v_urgency;
    END IF;

    -- 3. Insertar reporte principal
    INSERT INTO public.reports (
        type,
        urgency,
        description,
        location_text,
        lat,
        lng,
        contact_info
    ) VALUES (
        v_type::incident_type,
        v_urgency::urgency_level,
        v_description,
        v_location_text,
        v_lat,
        v_lng,
        v_contact_info
    ) RETURNING id INTO v_report_id;

    -- 4. Insertar desaparecido en caso de corresponder
    IF v_type = 'desaparecido' OR v_missing_person IS NOT NULL THEN
        IF v_missing_person IS NULL THEN
            RAISE EXCEPTION 'Se requiere el objeto "missing_person" para incidentes de tipo desaparecido.';
        END IF;

        v_mp_name := v_missing_person->>'full_name';
        v_mp_description := v_missing_person->>'physical_description';
        v_mp_last_seen := v_missing_person->>'last_seen_location';

        IF v_mp_name IS NULL OR v_mp_name = '' THEN
            RAISE EXCEPTION 'El campo "missing_person.full_name" es requerido.';
        END IF;

        INSERT INTO public.missing_persons (
            report_id,
            full_name,
            physical_description,
            last_seen_location
        ) VALUES (
            v_report_id,
            v_mp_name,
            v_mp_description,
            v_mp_last_seen
        );
    END IF;

    -- 5. Respuesta exitosa
    RETURN jsonb_build_object(
        'success', true,
        'report_id', v_report_id
    );
END;
$$;
