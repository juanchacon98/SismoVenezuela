# Usar la versión LTS de Node.js sobre Alpine Linux para reducir la superficie del contenedor
FROM node:20-alpine

# Definir el directorio de trabajo
WORKDIR /app

# Copiar archivos de dependencias
COPY package*.json ./

# Instalar solo las dependencias de producción
RUN npm ci --only=production

# Copiar el código fuente y el archivo SQL del esquema
COPY index.js migrate.js schema.sql ./

# Exponer el puerto por defecto de Google Cloud Run
EXPOSE 8080

# Definir variable de entorno para producción
ENV NODE_ENV=production

# El comando de inicio ejecuta las migraciones antes de levantar el servidor Express
CMD ["sh", "-c", "npm run migrate && npm start"]
