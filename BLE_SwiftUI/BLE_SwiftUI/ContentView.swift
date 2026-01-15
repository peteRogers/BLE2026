//
//  ContentView.swift
//  BLE_SwiftUI
//
//  Created by Peter Rogers on 15/01/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var ble = BLEController()

    @State private var messageToSend: Int = 1
    @State private var lastCallbackValue: Float = 0.0
    @State private var callbackLog: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {

                // Status
                VStack(alignment: .leading, spacing: 8) {
                    Text("Status: \(statusText(ble.status))")
                        .font(.headline)

                    Text("Connected flag: \(ble.isConnected() ? "true" : "false")")
                        .font(.subheadline)

                    Text("Last value (published): \(ble.lastArduinoValue, specifier: "%.3f")")
                        .font(.subheadline)

                    if let data = ble.lastRawData,
                       let s = String(data: data, encoding: .utf8) {
                        Text("Last raw: \(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()

                // Controls
                HStack(spacing: 12) {
                    Button {
                        wireCallbacksIfNeeded()
                        ble.connect()
                    } label: {
                        Text("Connect")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        ble.disconnect()
                    } label: {
                        Text("Disconnect")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                // Send
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Message: \(messageToSend)", value: $messageToSend, in: 0...9999)

                    HStack(spacing: 12) {
                        Button {
                            ble.sendData(id: 0, message: 1)
                        } label: {
                            Text("Send 1>")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ble.isConnected())

                        Button {
                            ble.sendData(id: 0, message: 2)
                        } label: {
                            Text("Send 2>")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ble.isConnected())
                    }
                }

                Divider()

                // Callback demo (optional)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Callback value: \(lastCallbackValue, specifier: "%.3f")")
                        .font(.subheadline)

                    if !callbackLog.isEmpty {
                        Text(callbackLog)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("BLE")
        }
        .onAppear {
            wireCallbacksIfNeeded()
        }
    }

    private func wireCallbacksIfNeeded() {
        // Keep closures if you want extra side-effects in the UI;
        // your BLEController already updates `lastArduinoValue` / `status`.
        ble.connectionChanged = { status in
            callbackLog = "connectionChanged: \(statusText(status))"
        }

        ble.arduinoData = { value in
            lastCallbackValue = value
        }

        ble.characteristicDidUpdateValue = { ok, data in
            if ok, let data, let s = String(data: data, encoding: .utf8) {
                callbackLog = "didUpdateValue: \(s)"
            } else {
                callbackLog = "didUpdateValue: (error)"
            }
        }
    }

    private func statusText(_ s: ConnectionStatus) -> String {
        switch s {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .disconnecting: return "disconnecting"
        case .unauthorized: return "unauthorized / not powered on"
        }
    }
}

#Preview {
    ContentView()
}
