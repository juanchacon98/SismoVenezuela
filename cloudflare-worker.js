/**
 * Cloudflare Worker: Telemetry & Google Analytics Collector & Reporter
 * 
 * Este worker serverless se ejecuta en el edge (Cloudflare) para:
 * 1. Interceptar y registrar mediciones de conectividad de los usuarios.
 * 2. Enviar eventos a Google Analytics 4 vía Measurement Protocol (v2).
 * 3. Consultar la API de Datos de GA4 (Data API v1) de manera segura usando una cuenta
 *    de servicio para extraer métricas de usuarios activos por estado de Venezuela.
 * 
 * Configuración de Variables y Secretos en Cloudflare:
 * - GA_MEASUREMENT_ID: Tu ID de Medición de GA4 (G-XXXXXXXXXX)
 * - GA_API_SECRET: Tu API Secret de Measurement Protocol
 * - GA_PROPERTY_ID: Tu ID de Propiedad de GA4 (ej: 123456789)
 * - GCP_SERVICE_ACCOUNT_EMAIL: El email de tu Cuenta de Servicio de Google Cloud
 * - GCP_PRIVATE_KEY: La clave privada PEM de tu Cuenta de Servicio (con saltos de línea \n)
 * - BACKEND_API_URL: La URL de tu backend en Cloud Run (https://...)
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. Manejo de CORS (Preflight requests y cabeceras comunes)
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Max-Age": "86400",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    // 2. Ruta GET /api/analytics-metrics (Obtener métricas reales de GA4)
    if (url.pathname === "/api/analytics-metrics" && request.method === "GET") {
      try {
        if (!env.GA_PROPERTY_ID || !env.GCP_SERVICE_ACCOUNT_EMAIL || !env.GCP_PRIVATE_KEY) {
          return new Response(JSON.stringify({ 
            error: "Faltan credenciales de Google API en las variables de entorno del Worker." 
          }), {
            status: 500,
            headers: { "Content-Type": "application/json", ...corsHeaders }
          });
        }

        // Obtener el token de acceso OAuth2 de Google
        const accessToken = await getGoogleAccessToken(
          env.GCP_SERVICE_ACCOUNT_EMAIL,
          env.GCP_PRIVATE_KEY
        );

        // Consultar la API de Datos de Google Analytics
        const gaMetrics = await fetchGA4Data(env.GA_PROPERTY_ID, accessToken);

        return new Response(JSON.stringify({ success: true, data: gaMetrics }), {
          status: 200,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      } catch (err) {
        console.error("Error al obtener métricas de GA4:", err.message);
        return new Response(JSON.stringify({ error: err.message }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      }
    }

    // 3. Ruta POST /api/telemetry (Existente, guardar y reenviar telemetría)
    if ((url.pathname === "/api/telemetry" || url.pathname === "/telemetry") && request.method === "POST") {
      try {
        const payload = await request.json();
        const { state, latency_ms } = payload;

        if (!state || latency_ms === undefined) {
          return new Response(JSON.stringify({ error: "Faltan campos requeridos: state y latency_ms" }), {
            status: 400,
            headers: { "Content-Type": "application/json", ...corsHeaders }
          });
        }

        const clientIp = request.headers.get("CF-Connecting-IP") || "0.0.0.0";
        const cfProperties = request.cf || {};

        // A. Enviar al backend principal
        const backendPromise = fetch(`${env.BACKEND_API_URL || 'https://ayuda-venezuela-backend-291864207498.us-central1.run.app'}/api/telemetry`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Forwarded-For": clientIp
          },
          body: JSON.stringify({ state, latency_ms })
        }).catch(err => console.error("Error al enviar al backend principal:", err.message));

        // B. Enviar a Google Analytics 4 vía Measurement Protocol
        let gaPromise = Promise.resolve();
        if (env.GA_MEASUREMENT_ID && env.GA_API_SECRET) {
          const gaUrl = `https://www.google-analytics.com/mp/collect?measurement_id=${env.GA_MEASUREMENT_ID}&api_secret=${env.GA_API_SECRET}`;
          const clientId = await sha256(clientIp);

          const gaPayload = {
            client_id: clientId,
            events: [{
              name: "connectivity_telemetry",
              params: {
                state: state,
                latency_ms: latency_ms,
                country: cfProperties.country || "VE",
                city: cfProperties.city || "Desconocida",
                asn: cfProperties.asn || 0,
                colo: cfProperties.colo || "CCS"
              }
            }]
          };

          gaPromise = fetch(gaUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(gaPayload)
          }).catch(err => console.error("Error al enviar a GA4:", err.message));
        }

        // Esperar a que ambas llamadas inicien/se procesen
        ctx.waitUntil(Promise.all([backendPromise, gaPromise]));

        return new Response(JSON.stringify({ success: true, message: "Telemetría recibida" }), {
          status: 202,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: err.message }), {
          status: 500,
          headers: { "Content-Type": "application/json", ...corsHeaders }
        });
      }
    }

    // 4. Ruta por defecto / Health check
    return new Response(JSON.stringify({ status: "ok", service: "SismoVenezuela Edge Telemetry Worker" }), {
      status: 200,
      headers: { "Content-Type": "application/json", ...corsHeaders }
    });
  }
};

// --- HELPERS DE CRIPTOGRAFÍA Y AUTENTICACIÓN GOOGLE ---

// Hashear la IP del cliente (SHA-256)
async function sha256(message) {
  const msgBuffer = new TextEncoder().encode(message);
  const hashBuffer = await crypto.subtle.digest("SHA-256", msgBuffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// Convertir ArrayBuffer a Base64URL
function arrayBufferToBase64Url(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  const base64 = btoa(binary);
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Convertir Base64 a ArrayBuffer
function base64ToArrayBuffer(base64) {
  const binaryString = atob(base64.replace(/-/g, '+').replace(/_/g, '/'));
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes.buffer;
}

// Obtener Token de Acceso de Google OAuth2 (firma JWT RS256 nativa)
async function getGoogleAccessToken(email, privateKeyPem) {
  const cleanKey = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  
  const binaryKey = base64ToArrayBuffer(cleanKey);

  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: { name: "SHA-256" }
    },
    false,
    ["sign"]
  );

  const header = { alg: "RS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: email,
    scope: "https://www.googleapis.com/auth/analytics.readonly",
    aud: "https://oauth2.googleapis.com/token",
    exp: now + 3600,
    iat: now
  };

  const textEncoder = new TextEncoder();
  const encodedHeader = arrayBufferToBase64Url(textEncoder.encode(JSON.stringify(header)));
  const encodedPayload = arrayBufferToBase64Url(textEncoder.encode(JSON.stringify(payload)));
  const assertionData = `${encodedHeader}.${encodedPayload}`;

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    signingKey,
    textEncoder.encode(assertionData)
  );

  const encodedSignature = arrayBufferToBase64Url(signature);
  const assertion = `${assertionData}.${encodedSignature}`;

  // Solicitar el token de acceso
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${assertion}`
  });

  if (!tokenResponse.ok) {
    const errorText = await tokenResponse.text();
    throw new Error(`Google OAuth error: ${errorText}`);
  }

  const tokenData = await tokenResponse.json();
  return tokenData.access_token;
}

// Consultar el Google Analytics Data API v1 para reportar usuarios por región
async function fetchGA4Data(propertyId, accessToken) {
  const url = `https://analyticsdata.googleapis.com/v1beta/properties/${propertyId}:runReport`;

  const requestBody = {
    dateRanges: [
      { startDate: "30daysAgo", endDate: "today" }
    ],
    dimensions: [
      { name: "region" } // Dimensión regional nativa de GA4 (nombres de estados)
    ],
    metrics: [
      { name: "activeUsers" }, // Usuarios activos en el período
      { name: "eventCount" }    // Total de eventos registrados
    ],
    dimensionFilter: {
      filter: {
        fieldName: "countryId",
        stringFilter: {
          value: "VE" // Filtrar exclusivamente para Venezuela
        }
      }
    }
  };

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(requestBody)
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`GA4 Data API error: ${errText}`);
  }

  const rawData = await response.json();
  return parseGA4Report(rawData);
}

// Procesar el reporte crudo de GA4 a un formato JSON limpio por estado
function parseGA4Report(report) {
  const results = {};
  if (!report.rows) return results;

  report.rows.forEach(row => {
    const stateName = row.dimensionValues[0].value; // Nombre de la región/estado
    const activeUsers = parseInt(row.metricValues[0].value, 10) || 0;
    const eventCount = parseInt(row.metricValues[1].value, 10) || 0;

    // Normalizar nombres de estados que reporta Google (ej: "Miranda State" -> "Miranda")
    const normalizedState = normalizeStateName(stateName);
    if (normalizedState) {
      results[normalizedState] = {
        active_users: activeUsers,
        total_pings: eventCount
      };
    }
  });

  return results;
}

// Helper para normalizar los nombres de estados devueltos por Google a nuestros estándar
function normalizeStateName(name) {
  if (!name) return null;
  const clean = name.toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "") // Eliminar tildes
    .replace(/\s+state$/, "")        // Eliminar sufijo " State"
    .trim();

  const mapping = {
    "distrito capital": "Distrito Capital",
    "caracas": "Distrito Capital",
    "amazonas": "Amazonas",
    "zoategui": "Anzoátegui",
    "anzoategui": "Anzoátegui",
    "apure": "Apure",
    "aragua": "Aragua",
    "barinas": "Barinas",
    "bolivar": "Bolívar",
    "carabobo": "Carabobo",
    "cojedes": "Cojedes",
    "delta amacuro": "Delta Amacuro",
    "falcon": "Falcón",
    "guarico": "Guárico",
    "lara": "Lara",
    "merida": "Mérida",
    "miranda": "Miranda",
    "monagas": "Monagas",
    "nueva esparta": "Nueva Esparta",
    "portuguesa": "Portuguesa",
    "sucre": "Sucre",
    "tachira": "Táchira",
    "trujillo": "Trujillo",
    "vargas": "La Guaira",
    "la guaira": "La Guaira",
    "yaracuy": "Yaracuy",
    "zulia": "Zulia"
  };

  for (const key in mapping) {
    if (clean.includes(key)) {
      return mapping[key];
    }
  }

  // Devolver el nombre capitalizado si no coincide exactamente
  return name;
}
