# Especificación Técnica de UI/UX e Implementación: Panel de Administración de Mailserver (PWA-First)
**Versión:** 2.0 (Actualizada con Control y Autorización de Dispositivos - DEVICEID)

---

## 1. Flujo de Primera Conexión y Registro de Dispositivo (Device Onboarding)

Para mitigar riesgos de endpoints expuestos en producción, la aplicación utiliza una arquitectura de confianza cero basada en un identificador único por dispositivo (`DEVICEID`). Ningún cliente (navegador web o PWA instalada) puede interactuar operacionalmente con la API de FastAPI sin una cabecera de dispositivo válida y autorizada.

### Pantalla Introductoria (Primer Inicio de la Aplicación)
1. **Petición Inicial:** Al abrir la PWA o el sitio web por primera vez, el sistema busca en el almacenamiento seguro local (`localStorage` / `IndexedDB`) la existencia de una clave `X-Device-ID`.
2. **Si no existe la clave:** La interfaz bloquea el Auth Gate tradicional y despliega la **Pantalla de Inicialización de Infraestructura**.
3. **Componentes Visuales de la Interfaz:**
   * **Campo de Entrada:** Formulario limpio para ingresar la URL base de la API del servidor de correo (`https://mail.dominio.com/api/v1`).
   * **Botón de Acción Principal:** `[⚙️ PROBAR CONEXIÓN]`.
4. **Mecánica de Handshake y Generación de ID:**
   * Al accionar el botón, el frontend realiza una petición especial hacia el servidor para verificar la validez del certificado SSL y la disponibilidad del backend.
   * Si la respuesta es exitosa (`200 OK`), el cliente frontend autogenera un identificador pseudoaleatorio criptográficamente seguro (UUID v4) mediante la Web Crypto API (`crypto.randomUUID()`).
   * Este identificador se guarda de forma persistente localmente bajo la clave estricta `X-Device-ID`.
   * **Nota Crítica:** En este punto, el dispositivo está en estado **"No Registrado / Pendiente de Autorización"** en el servidor, permitiendo únicamente el envío de credenciales para el proceso de enrolamiento.

---

## 2. Puerta de Acceso (Auth Gate) Adaptativa de Dos Factores

Una vez establecido el `DEVICEID` local, el frontend expone el formulario de autenticación, el cual inyectará dicho identificador en la cabecera `X-Device-ID` en cada intento de login.

```
MÓVIL (PWA Standalone)                  ESCRITORIO (Browser)
+-----------------------------------+   +-----------------------------------+
|            [ LOGO ]               |   |              [ LOGO ]             |
|                                   |   |                                   |
|  [ admin@dominio.com           ]  |   |  [ admin@dominio.com           ]  |
|  [ ••••••••••••••••            ]  |   |  [ ••••••••••••••••            ]  |
|                                   |   |                                   |
|      - O INICIAR SESIÓN CON -     |   |         [ SIGUIENTE: PASO 1 ]     |
|   [ 🧬 Huella / Rostro (Passkey) ] |   |                                   |
|                                   |   |  * El escritorio exige luego el   |
|  * En móvil, si usas biométricos, |   |    código 2FA (TOTP/Yubikey) en   |
|    te saltas la clave y el 2FA.   |   |    una segunda pantalla limpia.   |
+-----------------------------------+   +-----------------------------------+
```

### Lógica de Control de Flujo de Autenticación
* **Primer Acceso Histórico (Despliegue Inicial):** Si el servidor no tiene ningún dispositivo registrado en su base de datos, el primer login exitoso de un Súper Administrador marca automáticamente ese `DEVICEID` como **Autorizado**. Esto asegura el acceso inicial sin bloqueos mutuos (*deadlocks*).
* **Accesos Subsecuentes (Nuevos Dispositivos o Navegadores):** Cualquier intento de login posterior desde un nuevo dispositivo generará un nuevo `DEVICEID` local. Al realizar el login satisfactorio (Contraseña + 2FA o Biometría válidos), la API denegará el acceso operativo devolviendo un código de estado específico indicando que el dispositivo requiere autorización de un Súper Admin.

### Interfaz de Bloqueo por Dispositivo No Autorizado
Al recibir la respuesta de credenciales válidas pero dispositivo no autorizado, la interfaz transiciona inmediatamente a una pantalla estricta de bloqueo intermedio:

```
+-----------------------------------------------------------+
| 🔐 AUTENTICACIÓN EXITOSA - ESPERANDO AUTORIZACIÓN          |
|-----------------------------------------------------------|
| Tu cuenta ha sido validada correctamente. Sin embargo,    |
| este dispositivo de administración aún no ha sido aprobado.|
|                                                           |
| Identificador de este dispositivo:                        |
| [ DE793C1A-4F82-411B-9A74-5F1180210A88 ]  [📋 Copiar ID]  |
|                                                           |
| ⏳ Un Súper Administrador del sistema debe autorizar este|
|    dispositivo desde su panel de control para permitirte  |
|    el acceso completo.                                    |
|                                                           |
| [ 🔄 Verificar Estado de Aprobación ]      [ Volver ]     |
+-----------------------------------------------------------+
```
El botón **`[ Verificar Estado de Aprobación ]`** permite al usuario re-intentar el handshake con la API sin necesidad de volver a escribir sus credenciales, comprobando si el estado del dispositivo ha cambiado a activo en la base de datos central.

---

## 3. Panel de Control de Dispositivos (Vista de Súper Administradores)

La gestión y autorización de los puntos de administración en producción se centraliza en un módulo exclusivo accesible únicamente por cuentas con privilegios globales (Súper Administradores).

### Interfaz del Módulo de Gestión de Dispositivos
Este submódulo se integra dentro del área de Administración General (`⚙️ Admin`) y cuenta con alertas visuales de alta prioridad si existen registros en cola de espera.

```
PANELES DE DISPOSITIVOS (PWA Móvil)
+-----------------------------------------------------------+
| 💻 DISPOSITIVOS DE ADMIN                       [🔍 Buscar]|
+-----------------------------------------------------------+
| ⚠️ SOLICITUDES PENDIENTES (1)                              |
| 🆔 DE793C1A... (Android PWA)                              |
| 👤 Solicitante: carlos@empresa.com                         |
| [❌ Rechazar ]                        [🟢 AUTORIZAR (05s)]|
+-----------------------------------------------------------+
| ✓ DISPOSITIVOS ACTIVOS (3)                                |
|                                                           |
| 💻 MacBook Pro - Chrome (Principal Deploy)                |
| 🆔 A92B31F4... • 👤 admin@master.com • 🟢 Activo          |
|                                                           |
| 📱 Pixel 8 - Android PWA                                  |
| 🆔 F182C3D0... • 👤 superuser@master.com • 🟢 Activo      |
|                                                           |
| [🔴 Revocar Acceso (Exige Re-auth) ]                       |
+-----------------------------------------------------------+
```

### UX de Autorización y Revocación
* **Botón con Cuenta Regresiva:** Al igual que las acciones destructivas, el botón `[AUTORIZAR]` cuenta con un temporizador de protección de 5 segundos para asegurar que el Súper Admin verifique visualmente la identidad del solicitante y su ID de dispositivo antes de guardar la aprobación.
* **Revocación Inmediata:** Si se revoca un dispositivo (`[Revocar Acceso]`), la API destruye inmediatamente los tokens asociados a ese `DEVICEID`. El frontend de la máquina comprometida, al recibir la respuesta denegada en su siguiente llamada cíclica, borrará las credenciales en caché y pintará la pantalla de bloqueo de infraestructura.

---

## 4. Confirmación Crítica: El Guardián de Acciones Destructivas

Cualquier acción destructiva (eliminar un dominio, suspender un usuario o borrar un alias) no utiliza simples alertas del navegador o modales de confirmación genéricos. Requiere una re-autenticación visual explícita vinculada al par criptográfico o credencial activa del dispositivo.

```
HOJA DE CONFIRMACIÓN CRÍTICA (Despliegue inferior en PWA / Modal central en Escritorio)
+-----------------------------------------------------------+
| ⚠️ CONFIRMACIÓN DE SEGURIDAD                              |
| ¿Estás seguro de que deseas eliminar el dominio "viejodominio.com"? |
| Esta acción es permanente y destruirá 45 buzones activos.  |
|                                                           |
| [ 🧬 Confirmar con Biométricos ] <-- (Foco principal Android) |
|                                                           |
| O introduce tu contraseña de administrador para proceder: |
| [ ••••••••••••••••              ]                         |
|                                                           |
| [ CANCELAR ]                             [ ELIMINAR (05s) ] |
+-----------------------------------------------------------+
```
* **Mecánica:** Al autorizar la acción con biometría o clave, el frontend genera una firma que se envía junto a la cabecera del dispositivo. El botón final de confirmación hereda un retraso estricto por software para romper la automatización inconsciente de clics.

---

## 5. Arquitectura Adaptativa de Pantallas (Shell Layouts)

La interfaz se compone de componentes dinámicos que se contraen o expanden dependiendo de si se accede mediante un navegador convencional de escritorio o en la vista standalone PWA en Android.

### Vista de Escritorio (Estructura Multicolumna)
* **Sidebar Fijo Lateral:** Aloja el logotipo, el **Selector Global de Dominios** (estilo selector de espacios de Slack), y la navegación principal: Dominios, Usuarios, Administradores, Dispositivos y Logs.
* **Área de Trabajo Central:** Tablas de alta densidad que exponen los datos y las barras de cuotas de almacenamiento lineales y dinámicas (Azul $ightarrow$ Naranja $ightarrow$ Rojo).

### Vista Móvil / Standalone PWA (Diseño Ergonómico de Pulgar)
* **Header Fijo:** Muestra el menú de hamburguesa, el contexto del dominio activo actual y el icono de campana de notificaciones.
* **Barra de Navegación Inferior (Sticky Tab Bar):** El Sidebar de escritorio colapsa en botones inferiores de acceso rápido: `[⚙️ Admin]` (que incluye dispositivos), `[✉️ Accounts]`, y `[📋 Logs]`.
* **Floating Action Button (FAB):** Un botón flotante circular `[ + ]` posicionado en la esquina inferior derecha para la creación expedita de entidades (usuarios, alias o dominios) contextuales a la sección donde se encuentre el administrador.

---

## 6. Buscador Veloz (Rapid Search) con Filtro Multitarget

Un componente unificado de búsqueda rápida se sitúa de manera prominente en el header. Permite indexar coincidencias en tiempo real sin requerir navegación completa a listados secundarios.

* **Activación por Teclado:** Atajo global `CTRL + K` o `CMD + K` en ordenadores.
* **Componente Móvil:** Icono estático de lupa que expande una barra de búsqueda sobre el total del ancho de pantalla.
* **Resultados Categorizados:** El componente renderiza de forma segmentada las coincidencias mediante badges visuales unívocos:
  ```
  [ Buscar usuario o nombre... (ej. "Carlos")               ]
  +-----------------------------------------------------------+
  | 👤 Carlos Mendoza (carlos@empresa.com)       [Usuario]  v |
  | 👤 Carlos Silva (csilva@otro.com)            [Usuario]  v |
  | 🔀 carlos-ventas@empresa.com -> info@...     [Alias]    v |
  +-----------------------------------------------------------+
  ```
* Al accionar cualquier ítem de resultado, el frontend despliega una hoja deslizante lateral o inferior (`Drawer Component`) con los campos de edición del usuario manteniendo el fondo intacto, acelerando de este modo los flujos repetitivos de configuración.

---

## 7. CRUD de Entidades y Compatibilidad con PostfixAdmin

La interfaz gráfica mapea directamente los esquemas relacionales nativos de la base de datos de PostfixAdmin, agrupándolos bajo patrones UX modernos:

### CRUD de Usuarios
* **Campos Mapeados:** `Username` (Correo completo que actúa como clave primaria), `Name` (Nombre completo para búsquedas rápidas), `Password`, `Quota (MB)` (Entrada numérica enlazada a barra visual de capacidad) y el toggle binario `Active`.
* **Alias de Usuario In-situ:** Dentro de la misma edición de usuario, los alias asignados a dicha cuenta se visualizan como componentes interactivos de etiquetas con cierre (`Tags` con una `X` para desvinculación inmediata), simplificando la gestión de reenvíos sin cambiar de módulo.

### CRUD de Administradores (Súper vs. Personalizado)
* **Súper Administrador:** Al marcarse este rol, la sección inferior de selección de dominios se deshabilita visualmente cambiando a un estado bloqueado (`Disabled state`) con un patrón gráfico texturizado indicando *"Acceso global heredado sobre toda la infraestructura"*.
* **Administrador Personalizado (Custom Admin):** Se habilita dinámicamente un buscador y contenedor de etiquetas multiselección para agregar de forma restrictiva uno o más dominios específicos que dicho administrador tendrá permitido gestionar de manera aislada.

---

## 8. Gestión de Logs de Seguridad con Aislamiento Estricto

El flujo de logs proporciona visibilidad forense de todas las mutaciones realizadas en el mailserver, rigiéndose bajo el principio de menor privilegio.

```
+-----------------------------------------------------------+
| 📊 LOGS DE SEGURIDAD                           [ 🔍 FILTRAR ] |
+-----------------------------------------------------------+
| 🏷️ Filtrado por: [ 👤 carlos@empresa.com  (X) ]             | 
+-----------------------------------------------------------+
| [🟢] INICIO DE SESIÓN EXITOSO                   Hace 2 min |
| 🏷️ empresa.com  •  IP: 190.45.23.12                       |
+-----------------------------------------------------------+
| [🟡] CAMBIO DE CONTRASEÑA                      Ayer       |
| 🏷️ empresa.com  •  By: admin@empresa.com (Requiere Bio)   |
+-----------------------------------------------------------+
| [🔴] INTENTOS FALLIDOS DE 2FA                  12 Oct 2026|
| 🏷️ empresa.com  •  IP: 45.122.3.90  (5 bloqueos)          |
+-----------------------------------------------------------+
```

### Reglas UX de los Registros de Auditoría
* **Aislamiento Multi-tenant:** Los administradores personalizados solo visualizan logs cuyo tag de dominio coincida estrictamente con los dominios que tienen asignados. La interfaz omite los componentes de filtrado de dominios globales para estas cuentas.
* **Filtros Cruzados y Acceso Contextual:** En la vista de edición de cualquier usuario, existe el botón destacado `[🛡️ VER LOGS]`. Al presionarlo, el sistema transiciona a la pantalla de auditoría inyectando automáticamente un tag de filtro persistente (`[👤 usuario@dominio.com (X)]`), permitiendo auditar acciones sufridas o ejecutadas por esa cuenta específica de forma instantánea.
* **Despliegue de Detalles:** En la PWA, pulsar un registro de log no recarga la vista; despliega una hoja inferior nativa (`Bottom Sheet`) detallando la dirección IP, el ID del evento, la firma del `DEVICEID` autorizante y el endpoint consumido.

---

## 9. Directrices de Resiliencia, Rendimiento PWA y Estados Offline

### Comportamiento Sin Conexión (Offline Safety)
* La aplicación prohíbe explícitamente mutaciones operacionales estando offline. Si el Service Worker detecta la pérdida de conectividad de red, todos los botones de guardado, creación y eliminación se bloquean visualmente y se superpone un banner informativo de solo lectura: *"Sin conexión con el servidor. Operaciones de escritura bloqueadas por seguridad"*.
* Los datos de auditoría de logs ya descargados permanecen legibles localmente mediante almacenamiento persistente indexado, garantizando su consulta rápida en cualquier circunstancia.

### Ciclo de Vida en Segundo Plano y Suspensión (Backgrounding)
* Si la aplicación PWA se minimiza en Android o la pantalla del teléfono se bloquea por un período superior a **2 minutos**, al regresar a la aplicación, la UI intercepta el flujo cubriendo la pantalla por completo con un protector de privacidad. El usuario debe proporcionar verificación biométrica obligatoria (huella o rostro) para disolver el protector y continuar visualizando la información expuesta.
* Si el tiempo de inactividad excede los **15 minutos**, la sesión del token web de la API se purga por completo por razones de seguridad, obligando a realizar el flujo completo de autenticación de fase uno.

### Optimización y Fluidez Gráfica
* Los listados masivos de usuarios y logs implementan obligatoriamente un componente de **Scroll Infinito Virtualizado**. La memoria de renderizado del dispositivo móvil únicamente computa los nodos visibles en el viewport (aproximadamente 15-20 elementos), logrando una navegación suave y constante a 60 FPS en plataformas móviles Android sin degradar el rendimiento del hardware.