# Guía Técnica Complementaria: Arquitectura de la API y Tecnologías de la PWA
**Versión:** 2.0 (Actualizada con Control y Autorización de Dispositivos - DEVICEID)

---

## 1. Pila Tecnológica Recomendada (Production-Ready)

### Frontend (PWA Client)
* **Framework Principal:** **Vite + React.js** (utilizando TypeScript) o **SolidJS**. Se seleccionan por su velocidad de compilación, empaquetado ultra-ligero y excelente soporte para ciclo de vida de componentes reactivos en entornos móviles.
* **Gestión de PWA:** `@vite-pwa/plugin` para la inyección automática y control preciso del Service Worker, estrategias de caché (`CacheFirst` para assets, `NetworkOnly` para peticiones de mutación a la API) y manifiesto de instalación para Android.
* **Almacenamiento Local Seguro:** **Dexie.js** como wrapper robusto sobre `IndexedDB` para la persistencia local de la URL base de la API, configuraciones visuales e historial de auditoría de logs en caché de solo lectura.
* **Librería de Componentes & Estilos:** **Tailwind CSS** complementado con **Shadcn/ui** o **Mantine**, configurados con estilos específicos para deshabilitar el zoom nativo accidental en móviles y optimizados para responder a interacciones táctiles sin retraso (*zero touch delay*).
* **Deploy** el deploy en server deberá hacerse en los envs dev y prod de maild empaquetado como una imagen docker al efecto para servir el server web en un puerto al efecto
* **Android App** se generará app-generate.sh que con la ayuda de docker deberá compilar la PWA en una .apk para android, esto debe ser usado por un github actions para generar la apk como un artifact coo parte del release

### Backend (Mailserver API Engine)
* **Core del Framework:** **FastAPI (Python 3.14)**. Elegido por su velocidad de ejecución asíncrona basada en Starlette y Uvicorn, autogeneración de esquemas de validación mediante Pydantic v2 y soporte nativo para flujos de dependencias (`Depends`).
* **Server support** Empaquetado en una imagen docker basada en python:34-trixie, integrada al resto del stack de maild para el manejo de variables y a los entornos de dev y producción
* **DB support** postgres db usará la DB de maild legacy para el manejo de usuarios y dominio, con acceos total menos a cambiar la estructura de la DB, para el manejo de sus datos usará una db adicional (ver de talles en db service para provisionar esta DB extra)
* **Seguridad & Criptografía:** `PyJWT` para la emisión y validación de tokens de acceso de corta duración, y `Moshi` o `WebAuthn` para la gestión e interpretación de las aserciones criptográficas de llaves y biometría móvil.

---

## 2. Flujo de Control de Dispositivos: Handshake y Cabeceras Obligatorias

El sistema de FastAPI actúa como un guardián de confianza cero. Cada petición HTTP entrante, sin excepción (salvo el estado de salud de la API), es interceptada por un middleware intermedio que valida la existencia y el estado de la cabecera del dispositivo.

### Cabecera Mandatoria
Todas las llamadas de la aplicación deben inyectar la siguiente cabecera HTTP personalizada:
```http
X-Device-ID: DE793C1A-4F82-411B-9A74-5F1180210A88
```

### Ciclo de Estados del Dispositivo en el Backend
Un dispositivo registrado en la persistencia de datos transiciona por tres estados lógicos:
1. `PENDING`: Generado en el primer inicio de sesión de un usuario en una máquina nueva. Bloquea el uso de endpoints de gestión.
2. `APPROVED`: Autorizado explícitamente por un Súper Admin o auto-validado en el despliegue inicial. Habilita la interacción normal de la API según los roles del usuario.
3. `REVOKED`: Dispositivo bloqueado administrativamente. Cualquier petición con este ID retorna rechazo inmediato de autenticación.

---

## 3. Especificación de Endpoints y Contratos de la API (FastAPI Model)

A continuación se detallan los contratos JSON y las rutas de FastAPI necesarias para dar soporte a la lógica de control avanzada del sistema:

### A. Inicialización y Handshake del Dispositivo
* **Endpoint:** `POST /api/v1/device/handshake`
* **Descripción:** Valida la URL de la API del servidor desde la PWA por primera vez y registra el ID de dispositivo local en el backend en estado pendiente de aprobación.
* **Cabecera Requerida:** `X-Device-ID` (UUID v4 autogenerado en el cliente).
* **Payload de Entrada:**
  ```json
  {
    "client_type": "android_pwa",
    "device_name": "Pixel 8 Pro - Chrome Mobile"
  }
  ```
* **Respuesta Exitosa (`201 Created`):**
  ```json
  {
    "status": "registered",
    "device_id": "DE793C1A-4F82-411B-9A74-5F1180210A88",
    "authorization_state": "PENDING",
    "message": "Dispositivo registrado. Requiere aprobación administrativa previo al uso operacional."
  }
  ```

### B. Flujo de Autenticación de Dos Pasos
* **Endpoint Paso 1:** `POST /api/v1/auth/login-step1`
* **Cabecera Requerida:** `X-Device-ID`
* **Payload de Entrada:** `{"username": "admin@dominio.com", "password": "secure_password"}`
* **Respuestas Posibles:**
  * `200 OK` (Si el dispositivo ya está `APPROVED`): Avanza a la validación 2FA. `{"session_state": "REQUIRES_2FA", "flow_token": "xyz..."}`
  * `403 Forbidden` (Si las credenciales son válidas pero el dispositivo está `PENDING`): Detiene el flujo y activa la pantalla de bloqueo en el cliente.
    ```json
    {
      "detail": "DEVICE_NOT_AUTHORIZED",
      "device_id": "DE793C1A-4F82-411B-9A74-5F1180210A88",
      "associated_user": "admin@dominio.com"
    }
    ```

* **Endpoint Verificación de Estado (Polling del Cliente):** `GET /api/v1/device/status`
* **Cabecera Requerida:** `X-Device-ID`
* **Respuesta Exitosa (`200 OK`):**
  ```json
  {
    "device_id": "DE793C1A-4F82-411B-9A74-5F1180210A88",
    "authorization_state": "APPROVED" 
  }
  ```

### C. Módulo de Gestión y Aprobación de Dispositivos (Súper Admin)
* **Endpoint Listar Solicitudes:** `GET /api/v1/admin/devices`
* **Descripción:** Retorna la lista de dispositivos registrados. Si es un Súper Admin ve todo; si es Custom Admin, esta ruta devuelve un código `403`.
* **Respuesta Exitosa (`200 OK`):**
  ```json
  [
    {
      "device_id": "DE793C1A-4F82-411B-9A74-5F1180210A88",
      "device_name": "Pixel 8 Pro - Chrome Mobile",
      "associated_user": "carlos@empresa.com",
      "authorization_state": "PENDING",
      "registered_at": "2026-10-16T21:10:00Z"
    }
  ]
  ```

* **Endpoint Modificar Estado (Aprobar/Revocar):** `PUT /api/v1/admin/devices/{device_id}/state`
* **Payload de Entrada:** `{"action": "APPROVE"}` o `{"action": "REVOKE"}`
* **Respuesta Exitosa (`200 OK`):**
  ```json
  {
    "device_id": "DE793C1A-4F82-411B-9A74-5F1180210A88",
    "new_state": "APPROVED",
    "authorized_by": "superadmin@master.com"
  }
  ```

### D. Buscador Indexado de Acceso Rápido
* **Endpoint:** `GET /api/v1/mailserver/search`
* **Descripción:** Retorna resultados mixtos limitados estrictamente por las restricciones multi-tenant del token del administrador autenticado.
* **Parámetros de Consulta:** `?q=carlos`
* **Respuesta Exitosa (`200 OK`):**
  ```json
  {
    "query": "carlos",
    "results": [
      {
        "type": "user",
        "id": "carlos@empresa.com",
        "display_name": "Carlos Mendoza",
        "domain": "empresa.com",
        "details": { "quota_mb": 10240, "quota_used_mb": 5530, "active": true }
      },
      {
        "type": "alias",
        "id": "carlos-ventas@empresa.com",
        "display_name": "Alias de Ventas Carlos",
        "domain": "empresa.com",
        "details": { "goto": "info@empresa.com", "active": true }
      }
    ]
  }
  ```

---

## 4. Control de Acciones Destructivas: Token de Doble Validación

Para garantizar de forma matemática que ninguna acción crítica (como eliminar un dominio) sea ejecutada mediante un ataque de inyección o saltándose la UI, la API de FastAPI implementa una barrera temporal criptográfica.

### El Token de Validación Efímera (`X-Security-Validation-Token`)
1. Al realizar de forma exitosa la confirmación biométrica o contraseña en el cuadro del "Guardián de Acciones Destructivas", el frontend llama primero al endpoint interno `POST /api/v1/auth/reauth-confirm`.
2. Si la validación es correcta, FastAPI expide un token JWT efímero con un tiempo de expiración estricto de **30 segundos**.
3. El frontend captura este token y lo adjunta obligatoriamente en la cabecera HTTP de la petición de borrado final:
   ```http
   DELETE /api/v1/mailserver/domains/viejodominio.com
   X-Device-ID: DE793C1A-4F82-411B-9A74-5F1180210A88
   X-Security-Validation-Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
   ```
4. Si la cabecera del token de validación falta, está vencida o no corresponde al mismo `DEVICEID` que originó la sesión, FastAPI interrumpe el ciclo de ejecución de la petición y devuelve un código de error `403 Operation Not Verified`, protegiendo la base de datos de PostfixAdmin de cualquier alteración no autorizada.