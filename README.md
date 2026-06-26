# Ayuda Venezuela — Centro de Monitoreo de Emergencias y Conectividad

Plataforma humanitaria de alta disponibilidad y contingencia diseñada para centralizar incidentes, ubicar personas desaparecidas y evaluar el estado de la conectividad de red a nivel nacional tras el sismo en Venezuela.

---

## 🚀 Arquitectura del Sistema

El proyecto está diseñado con un modelo híbrido resiliente para garantizar baja latencia y alta tolerancia a fallos:

1.  **Frontend (Vanilla JS / CSS / HTML)**: Panel interactivo premium con mapa de topología de red nacional (SVG), visualización de sismos recientes (conectado a la API de USGS) y reportes ciudadanos de emergencias y personas desaparecidas.
2.  **Backend (Node.js / Express / PostgreSQL)**: Desplegado en **Google Cloud Run** y conectado a **Cloud SQL**. Administra incidentes, centros de acopio y gestiona la ingesta de base de datos externas.
3.  **Capa Serverless (Cloudflare Workers)**: Worker desplegado en `api.vnzl.technolink.tech` que firma JWTs locales mediante **Web Crypto (RS256)** para consultar de forma segura la API v1 de Google Analytics (GA4) y retornar telemetría de tráfico por estados en tiempo real sin revelar secretos.
4.  **Raspado con IA (ScrapeGraphAI + Gemini)**: Script en Python (`database/scrape_missing.py`) ejecutado por el backend para scrapear de forma inteligente, parsear y deduplicar personas desaparecidas desde el portal `desaparecidosterremotovenezuela.com`.

---

## 🛠️ Requisitos de Desarrollo

*   **Node.js**: versión 20.x o superior
*   **Python**: versión 3.11.x o superior
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

# Sincronización mediante API/URL (Opcional)
MISSING_PERSONS_SOURCE_NAME=desaparecidosterremotovenezuela.com
MISSING_PERSONS_SYNC_INTERVAL_MS=21600000 # 6 horas por defecto

# API Key de Gemini para el Scraper Inteligente y la consola de IA
GEMINI_API_KEY=tu_gemini_api_key
```

### 4. Iniciar Servidor
```bash
npm start
```
El servidor estará escuchando en `http://localhost:8080`.

---

## 🤖 Motor de Scraping Inteligente (ScrapeGraphAI)

Para evitar el uso de APIs propietarias restringidas por reCAPTCHA, el sistema integra un scraper basado en LLM que lee directamente el portal `desaparecidosterremotovenezuela.com`.

*   **Ejecución automática**: El programador en segundo plano (`startMissingPersonsSyncScheduler`) ejecuta el scraper automáticamente cada **6 horas**.
*   **Deduplicación Semántica**: Los registros obtenidos se procesan en lote. Se comparan similitudes trigramáticas (`pg_trgm`) en PostgreSQL. Si una persona tiene un nombre similar (>72%) o coincidencia parcial de ubicación-nombre, sus datos de contacto y fuentes se fusionan automáticamente en lugar de crear un reporte duplicado.
*   **Parche de Compatibilidad**: El scraper incluye un parche dinámico de inyección en `sys.modules` para sortear la deprecación de `ChatOllama` en las últimas versiones de `langchain-community`, garantizando la estabilidad del entorno.

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
