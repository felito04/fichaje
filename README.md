# MyUrbanScoot Fichaje NFC

Aplicación Flutter para una tablet Android fija. Lee credenciales cifradas de una tarjeta NFC, inicia una sesión efímera en Medusa v2 y registra entrada, salida o pausa con la hora del servidor.

## Estado

Incluye:

- quiosco horizontal con reloj de Madrid, cuenta atrás de 4 segundos, confirmación y antirrebote de 10 segundos;
- cliente Medusa para `login`, `today`, entrada, salida y pausas, con timeout de 10 segundos y un reintento que conserva la misma clave de idempotencia;
- cierre seguro de una pausa antes de fichar una salida;
- sobre `MUSF` v1 con AES-256-GCM, nonce aleatorio, UID como AAD y rotación de claves;
- almacenamiento de claves y PIN mediante Android Keystore (`flutter_secure_storage`);
- drivers intercambiables para MIFARE Classic 1K y NDEF;
- protección de escritura por contraseña para NTAG213/215/216 detectados mediante `GET_VERSION`;
- administración para validar usuarios, programar/verificar/borrar tarjetas, diagnosticar tecnologías y sectores, configurar staging/producción y transferir claves por QR;
- modo inmersivo, pantalla encendida, screen pinning/Lock Task y receptor de arranque;
- pruebas unitarias del estado diario y del sobre cifrado, incluido el rechazo al copiarlo a otro UID.

## Desarrollo

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

El APK de depuración queda en `build/app/outputs/flutter-apk/app-debug.apk`.

## Primera puesta en marcha

1. Instalar la app en una tablet Android y activar NFC.
2. Tocar cinco veces el logotipo para crear el PIN de administración.
3. En **Configuración**, introducir obligatoriamente la URL de staging antes de probar. Definir el identificador de tablet, las coordenadas fijas si se desean y los sectores MIFARE permitidos (por defecto `13,14,15`).
4. Usar **Probar tarjeta** con una tarjeta real. Para MIFARE Classic debe aparecer la tecnología `MifareClassic`; si no aparece, el chip NFC de la tablet no es compatible.
5. Programar una tarjeta con un usuario de staging y completar entrada → pausa → fin de pausa → salida. Confirmar las marcas y la nota del quiosco en Medusa.
6. Exportar el QR de claves y custodiarlo fuera de la tablet.

Las credenciales descifradas no se registran ni se guardan en la tablet. El token de Medusa solo vive durante un flujo de fichaje.

## Lock Task

`startLockTask()` activa screen pinning en una tablet normal. Para un quiosco sin confirmación del sistema, la app debe provisionarse como *device owner* en una tablet recién restablecida y autorizarse como paquete Lock Task mediante una política MDM/DPC. Android no permite que una app corriente se conceda a sí misma ese privilegio.

El receptor `BOOT_COMPLETED` intenta abrir la app al arrancar. Las versiones recientes de Android o la política del fabricante pueden limitar el arranque en segundo plano; en producción debe autorizarse el autoarranque o desplegarse con MDM/launcher de quiosco.

## Seguridad de tarjetas

- MIFARE nunca toca el sector 0 ni sectores fuera de la lista configurada. Solo reutiliza sectores vacíos con clave de fábrica o sectores que ya pertenecen a esta app.
- Las claves A/B MIFARE se derivan de la clave maestra y del UID. El tráiler usa los bits `FF 07 80 69`, comprobados antes de cada escritura.
- NDEF usa un registro MIME `application/vnd.myurbanscoot.fichaje`. Solo los modelos NTAG21x reconocidos reciben comandos de protección; otros tags NDEF no reciben escrituras de configuración propietarias.
- La contraseña NTAG evita sobrescrituras accidentales, pero no convierte NTAG ni MIFARE Classic en tarjetas criptográficamente resistentes a clonación.

## Antes de producción

- Probar físicamente cada modelo de tablet/tarjeta y verificar que cualquier sistema previo de puerta o alarma continúa funcionando.
- Configurar firma release; el proyecto conserva deliberadamente la firma debug del template para desarrollo.
- Provisionar Lock Task/autoarranque con el MDM elegido.
- No probar tarjetas ni fichajes por primera vez contra producción.
