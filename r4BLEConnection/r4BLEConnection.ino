#include <ArduinoBLE.h>

// Must match your iOS UUIDs exactly:
const char* SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";

// Two-way characteristics (match iOS BLEController):
// TX (Arduino -> iOS): notify/read
const char* CHAR_TX_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a9";
// RX (iOS -> Arduino): write
const char* CHAR_RX_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26aa";

BLEService dataService(SERVICE_UUID);
BLECharacteristic txChar(CHAR_TX_UUID, BLERead | BLENotify, 40);
BLECharacteristic rxChar(CHAR_RX_UUID, BLEWrite, 40);

unsigned long lastSendMs = 0;

// Example telemetry source (replace with your sensor/ADC/etc.)
float readValue() {
  int raw = analogRead(A0);
  return raw / 1023.0f; // 0..1
}

// --- Stream parser for RX messages like: 0:1> ---
// We buffer because BLE writes can arrive in chunks.
String rxBuffer;

static inline void handleMessage(const String& msg) {
  // Expected: "<address>:<value>"
  // Example: "0:1"
  int colon = msg.indexOf(':');
  if (colon < 0) {
    Serial.print("Bad msg (no ':'): ");
    Serial.println(msg);
    return;
  }

  String addrStr = msg.substring(0, colon);
  String valStr  = msg.substring(colon + 1);

  addrStr.trim();
  valStr.trim();

  int address = addrStr.toInt();
  int value   = valStr.toInt();

  Serial.print("Parsed address=");
  Serial.print(address);
  Serial.print(" value=");
  Serial.println(value);

  // ---- Do something with (address, value) ----
  // Example: address 0 controls LED, value 0/1 off/on
  if (address == 0) {
    if(value == 2){
      digitalWrite(LED_BUILTIN, HIGH);
    }
    if(value == 1){
      digitalWrite(LED_BUILTIN, LOW);
    }
   

    
    
  }

  // Add more addresses here...
}

static inline void feedRxBytes(const char* data, int n) {
  for (int i = 0; i < n; i++) {
    char c = data[i];

    // End-of-message marker is '>'
    if (c == '>') {
      // We got a complete message payload in rxBuffer, process it.
      String msg = rxBuffer;
      rxBuffer = "";

      msg.trim();
      if (msg.length() > 0) {
        handleMessage(msg);
      }
      continue;
    }

    // Ignore newlines (optional)
    if (c == '\r' || c == '\n') continue;

    // Accumulate
    rxBuffer += c;

    // Safety: prevent runaway if terminator never arrives
    if (rxBuffer.length() > 120) {
      Serial.println("RX buffer overflow, clearing");
      rxBuffer = "";
    }
  }
}

void setup() {
  Serial.begin(115200);
  while (!Serial) {}

  if (!BLE.begin()) {
    Serial.println("BLE.begin() failed.");
    while (1) delay(1000);
  }

  BLE.setLocalName("UNO-R4-BLE");
  BLE.setDeviceName("UNO-R4-BLE");
  BLE.setAdvertisedService(dataService);

  dataService.addCharacteristic(txChar);
  dataService.addCharacteristic(rxChar);
  BLE.addService(dataService);

  // Initial TX value
  txChar.writeValue((const uint8_t*)"0.0000>", 7);

  BLE.advertise();
  Serial.println("BLE advertising as UNO-R4-BLE...");
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  BLEDevice central = BLE.central();

  if (central) {
    Serial.print("Connected to central: ");
    Serial.println(central.address());

    while (central.connected()) {
      // 1) Receive commands from iOS on RX characteristic
      if (rxChar.written()) {
        int len = rxChar.valueLength();
        if (len > 0) {
          uint8_t raw[64];
          int n = (len < (int)sizeof(raw)) ? len : (int)sizeof(raw);
          rxChar.readValue(raw, n);

          // Debug: print the raw chunk
          Serial.print("RX chunk (");
          Serial.print(n);
          Serial.print("): ");
          for (int i = 0; i < n; i++) Serial.write((char)raw[i]);
          Serial.println();

          // Feed into stream parser
          feedRxBytes((const char*)raw, n);
        }
      }

      // 2) Send telemetry to iOS on TX characteristic (Notify)
      if (millis() - lastSendMs >= 50) { // 20 Hz
        lastSendMs = millis();

        float v = readValue();

        char buf[32];
        // keep your original telemetry format: "0.1234>"
        snprintf(buf, sizeof(buf), "%.4f>", v);

        txChar.writeValue((const uint8_t*)buf, strlen(buf));
      }

      BLE.poll();
    }

    Serial.println("Disconnected.");
    rxBuffer = "";
  }
}