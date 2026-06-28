# Ayuda Venezuela — Centro de Monitoreo de Emergencias y Conectividad

Plataforma humanitaria de alta disponibilidad y contingencia diseñada para centralizar incidentes, ubicar personas desaparecidas y evaluar el estado de la conectividad de red a nivel nacional tras el sismo en Venezuela.

---

## 🚀 Arquitectura del Sistema

El proyecto está diseñado con un modelo híbrido resiliente para garantizar baja latencia y alta tolerancia a fallos:

1.  **Frontend (Vanilla JS / CSS / HTML)**: Panel interactivo premium con mapa de topología de red nacional (SVG), visualización de sismos recientes (conectado a la API de USGS) y reportes ciudadanos de emergencias y personas desaparecidas.
2.  **Backend (Node.js / Express / PostgreSQL)**: Desplegado en **Google Cloud Run** y conectado a **Cloud SQL**. Administra incidentes, centros de acopio y gestiona la ingesta de base de datos externas.
3.  **Capa Serverless (Cloudflare Workers)**: Worker desplegado en `api.vnzl.technolink.tech` que firma JWTs locales mediante **Web Crypto (RS256)** para consultar de forma segura la API v1 de Google Analytics (GA4) y retornar telemetría de tráfico por estados en tiempo real sin revelar secretos.
4.  **Ingesta y federacion de desaparecidos**: El backend importa lotes autorizados, ejecuta deduplicacion en PostgreSQL y publica un feed `GET /pfif` compatible con PFIF 1.5 para integracion con Localizalo.

---

## 🛠️ Requisitos de Desarrollo

*   **Node.js**: versión 20.x o superior
*   **PostgreSQL**: versión 15 o superior (con extensión `pg_trgm` habilitada para deduplicación semántica)

---

## 💻 Instalación y Configuración Local

### 1. Clonar el repositorio e instalar dependencias de Node
```bash
npm install
```

### 2. Configurar base de datos
Ejecuta los scripts SQL de `database/schema.sql` en tu instancia de PostgreSQL para crear la estructura de tablas. Luego ejecuta las migraciones:
```bash
npm run migrate
```

### 3. Configurar Variables de Entorno (`.env`)
Crea un archivo `.env` en la raíz del proyecto basado en `.env.example`:
```ini
PORT=8080
DATABASE_URL=postgres://tu_usuario:tu_contraseña@localhost:5432/emergencia_ccs
PUBLIC_BASE_URL=https://ayudaterremoto.rv2ven.com
PFIF_NAMESPACE=ayudaterremoto.rv2ven.com

# Sincronización mediante API/URL (Opcional)
MISSING_PERSONS_SOURCE_NAME=desaparecidosterremotovenezuela.com
MISSING_PERSONS_SYNC_INTERVAL_MS=600000 # 10 minutos; el backend no permite menos

# API Key de Gemini para sincronizacion asistida y consola de IA
GEMINI_API_KEY=tu_gemini_api_key
```

### 4. Iniciar Servidor
```bash
npm start
```
El servidor estará escuchando en `http://localhost:8080`.

---

## 🤖 Ingesta de Personas Desaparecidas

Para evitar saltarse protecciones como reCAPTCHA, el sistema prioriza una fuente JSON/API autorizada configurada con `MISSING_PERSONS_SYNC_URL`. Si no existe esa fuente, puede ejecutar una sincronizacion asistida por Gemini desde el contenido publico disponible, con deduplicacion posterior.

*   **Ejecución automática**: El programador en segundo plano (`startMissingPersonsSyncScheduler`) ejecuta la sincronizacion cada **10 minutos** si asi se configura, con backoff automatico cuando hay fallos.
*   **Deduplicación Semántica**: Los registros obtenidos se procesan en lote. Se comparan similitudes trigramáticas (`pg_trgm`) en PostgreSQL. Si una persona tiene un nombre similar (>72%) o coincidencia parcial de ubicación-nombre, sus datos de contacto y fuentes se fusionan automáticamente en lugar de crear un reporte duplicado.
*   **Estados federados**: Los reportes activos se exportan como `status=missing`; los reportes marcados como resueltos se exportan como `status=found`.

## 🔎 Feed PFIF 1.5 para Localizalo

El endpoint publico `GET /pfif` cumple el contrato solicitado por Localizalo:

```http
GET /pfif?updated_after=1970-01-01T00:00:00Z&offset=0&limit=1000
Accept: application/xml
```

*   Devuelve PFIF 1.5 XML cuando el cliente envia `Accept: application/xml` o `?format=xml`.
*   Devuelve JSON plano cuando el cliente envia `Accept: application/json` o no negocia XML.
*   Ordena por `source_date` ascendente y usa `updated_at` real para que `updated_after` no pierda cambios.
*   Soporta `offset` y `limit` hasta 1000 registros por pagina.

Entrada sugerida para `apps/etl/sources.yml` en `jorgerojas26/localizalo`:

```yaml
sources:
  - id: sismo-venezuela
    name: SismoVenezuela
    namespace: ayudaterremoto.rv2ven.com
    base_url: https://ayudaterremoto.rv2ven.com
    rate_limit_ms: 100
```

---

## 🚢 Despliegue en Producción

### 🐳 Google Cloud Run (Backend)
El despliegue está automatizado mediante GitHub Actions (`.github/workflows/deploy.yml`). Al realizar un push a la rama `main`, se ejecutan las siguientes acciones:
1. Se compila la imagen Docker (Node.js 20-Alpine) y se sube a Google Artifact Registry.
2. Se despliega en Google Cloud Run inyectando las variables de entorno desde los secretos del repositorio.

#### 🔑 GitHub Secrets requeridos
Configura estos secretos en **Settings → Secrets and variables → Actions** de tu repositorio:

| Secret | Descripción |
|---|---|
| `GCP_SA_KEY` | JSON completo de la clave de la Service Account de GCP con permisos para Artifact Registry y Cloud Run |
| `GCP_PROJECT_ID` | ID del proyecto en Google Cloud (ej. `praxis-ia-498305`) |
| `DATABASE_URL` | Connection string completo de PostgreSQL (Cloud SQL) |
| `GEMINI_API_KEY` | API Key de Google AI Studio para el motor de IA (`/api/sync-external`) |
| `MISSING_PERSONS_SYNC_URL` | (Opcional) URL del endpoint autorizado para sincronizar personas desaparecidas |

### ⚡ Cloudflare Workers (Telemetría)
Para actualizar y desplegar el worker serverless de telemetría de GA4:
```bash
npx wrangler deploy
```
Asegúrate de configurar los secretos en Cloudflare:
```bash
echo "tu_priv_key_gcp" | npx wrangler secret put GCP_PRIVATE_KEY
echo "correo_servicio_gcp" | npx wrangler secret put GCP_SERVICE_ACCOUNT_EMAIL
```
