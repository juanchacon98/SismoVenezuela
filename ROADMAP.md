# Roadmap Humanitario

Este documento prioriza las mejoras pendientes para que SismoVenezuela sea mas util, seguro y sostenible durante una respuesta humanitaria.

## P0 - Impacto inmediato y seguridad operativa

1. Registrar el feed PFIF en Localizalo.
   - `base_url`: `https://ayudaterremoto.rv2ven.com`
   - Endpoint: `GET /pfif?updated_after=<ISO>&offset=<int>&limit=<int>`
   - Formatos: PFIF 1.5 XML y JSON plano.
2. Configurar una fuente autorizada para desaparecidos.
   - Usar `MISSING_PERSONS_SYNC_URL` cuando exista un export/API permitido.
   - No intentar saltarse reCAPTCHA ni protecciones del sitio fuente.
3. Proteger endpoints sensibles o costosos.
   - `/api/import/missing-persons/sync`
   - `/api/scrape-missing`
   - `/api/sync-external`
   - `/api/reports/:id/resolve`
   - `POST /api/collection-centers`
4. Agregar rate limiting por IP.
   - Limites mas estrictos para endpoints de IA y escritura.
   - Limites moderados para telemetria y consultas publicas.
5. Definir un rollback operativo.
   - Backup antes de cada despliegue.
   - Comando documentado para restaurar archivos y reiniciar PM2.

## P1 - Calidad de datos y moderacion

1. Crear panel de moderacion.
   - Verificar reportes.
   - Ocultar registros falsos o sensibles.
   - Fusionar duplicados.
   - Marcar personas como localizadas.
2. Ampliar estados de personas.
   - `missing`
   - `found`
   - `injured`
   - `deceased`
   - `unknown`
3. Agregar cola de duplicados probables.
   - La IA o trigram similarity solo sugiere.
   - Una persona humana confirma la fusion.
4. Reducir exposicion de datos sensibles.
   - No publicar telefonos completos sin control.
   - Separar contacto privado de metadatos publicos.
5. Crear auditoria.
   - Quien cambio un registro.
   - Que cambio.
   - Fecha y motivo.

## P2 - UX movil y baja conectividad

1. Modo baja conexion.
   - Texto primero.
   - Mapas y graficas bajo demanda.
   - Menos dependencias CDN en la primera carga.
2. Cargar Chart.js de forma lazy.
   - Igual que Leaflet.
   - Solo cuando la seccion de sismos entra en pantalla.
3. Hacer dinamica la consulta de USGS.
   - Evitar `starttime` fijo.
   - Consultar una ventana reciente, por ejemplo ultimos 30 dias.
4. Optimizar polling.
   - Reducir refrescos cuando la pestana no esta visible.
   - Separar datos criticos de datos secundarios.
5. PWA/offline basica.
   - Telefonos de emergencia cacheados.
   - Centros de acopio recientes.
   - Ultimo estado de conectividad conocido.

## P3 - Operacion y confiabilidad

1. Backups automaticos de PostgreSQL.
   - Backup diario.
   - Retencion definida.
   - Prueba periodica de restauracion.
2. Monitoreo.
   - Alertas si `/health` falla.
   - Alertas si `/pfif` falla.
   - Alertas si la sincronizacion acumula errores.
3. Deploy reproducible.
   - Produccion como checkout Git o release empaquetado.
   - Version visible en `/health`.
   - Rollback por commit o release.
4. Pruebas automatizadas.
   - Contrato `/pfif`.
   - Deduplicacion.
   - Importacion de desaparecidos.
   - Formularios publicos.
5. Seguridad de cabeceras y abuso.
   - Revisar CORS.
   - CSP para frontend.
   - Validacion mas estricta de entradas.

## Proximo paso recomendado

Primero registrar `https://ayudaterremoto.rv2ven.com` como fuente en Localizalo y luego proteger endpoints sensibles. Eso aumenta el impacto real del proyecto y reduce el riesgo operativo antes de seguir agregando automatizacion.
