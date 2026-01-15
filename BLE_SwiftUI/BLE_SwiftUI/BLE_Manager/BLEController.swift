//
//  BLEManager.swift
//  BLE_SwiftUI
//
//  Created by Peter Rogers on 15/01/2026.
//

//
//  BLEController.swift
//  ble_Camera
//
//  SwiftUI-friendly version (no UIKit)
//  Uses @Observable (Observation) instead of ObservableObject
//

import Foundation
import CoreBluetooth
import Observation

enum ConnectionStatus {
    case connecting
    case connected
    case disconnected
    case disconnecting
    case unauthorized
}

@MainActor
@Observable
final class BLEController: NSObject {
    // SwiftUI-friendly state (auto-observed by @Observable)
    private(set) var status: ConnectionStatus = .disconnected
    private(set) var lastArduinoValue: Float = 0.0
    private(set) var lastRawData: Data?

    // Optional callbacks (kept to match your existing closure style)
    var characteristicDidUpdateValue: ((Bool, Data?) -> Void)?
    var connectionChanged: ((ConnectionStatus) -> Void)?
    var arduinoData: ((Float) -> Void)?

    // BLE internals
    private var hasUpdated = true
    private var token: NSKeyValueObservation?
    private var central: CBCentralManager?
    private var myPeripheral: CBPeripheral?

    // Two-way: TX = notify/read from peripheral -> iOS, RX = write from iOS -> peripheral
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    private let bleService = "4fafc201-1fb5-459e-8fcc-c5c9c331914b"

    // These must match your Arduino code.
    // TX (notify/read):  ...26a9
    // RX (write):       ...26aa
    private let bleTxCharacteristic = "beb5483e-36e1-4688-b7f5-ea07361b26a9"
    private let bleRxCharacteristic = "beb5483e-36e1-4688-b7f5-ea07361b26aa"

    private let bleServiceUUID = CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")
    private let bleTxCharacteristicUUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a9")
    private let bleRxCharacteristicUUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26aa")

    private var timeoutTimer: Timer?
    private(set) var connecting = false

    // MARK: - Public API

    func connect() {
        central = CBCentralManager(delegate: self, queue: nil)
        hasUpdated = true
    }

    func disconnect() {
        connecting = false
        if let c = central, let p = myPeripheral {
            c.cancelPeripheralConnection(p)
        }
        hasUpdated = true
        setStatus(.disconnected)
    }

    func isConnected() -> Bool {
        guard let p = myPeripheral else { return false }
        return p.state == .connected && rxCharacteristic != nil
    }

    func sendData(id: Int, message: Int) {
        guard
            let p = myPeripheral,
            let mc = rxCharacteristic,
            p.state == .connected
        else {
            print("sendData blocked: missing peripheral or RX characteristic", myPeripheral?.state as Any, rxCharacteristic as Any)
            return
        }

        hasUpdated = false

        let s = "\(id):\(message)>"
        guard let dataToSend = s.data(using: .utf8) else {
            hasUpdated = true
            return
        }

        p.writeValue(dataToSend, for: mc, type: .withResponse)
    }

    func send(channel: Int, message: Int) {
        guard
            let p = myPeripheral,
            let mc = rxCharacteristic,
            p.state == .connected
        else {
            print("Send blocked: missing peripheral or RX characteristic", myPeripheral?.state as Any, rxCharacteristic as Any)
            return
        }

        // Allow sending even if the peripheral never notifies; we re-enable on didWriteValueFor.
        hasUpdated = false

        let s = "\(channel)>\(message)<"
        guard let dataToSend = s.data(using: .utf8) else {
            hasUpdated = true
            return
        }

        // Choose write type based on characteristic properties.
        let supportsWrite = mc.properties.contains(.write)
        let supportsWriteNoResp = mc.properties.contains(.writeWithoutResponse)

        if supportsWrite {
            print("Writing (withResponse):", s)
            p.writeValue(dataToSend, for: mc, type: .withResponse)
        } else if supportsWriteNoResp {
            print("Writing (withoutResponse):", s)
            p.writeValue(dataToSend, for: mc, type: .withoutResponse)
            // No callback for withoutResponse on many peripherals, so re-enable immediately.
            hasUpdated = true
        } else {
            print("Characteristic is not writable. Props:", mc.properties)
            hasUpdated = true
        }
    }

    // MARK: - Helpers

    private func setStatus(_ newStatus: ConnectionStatus) {
        status = newStatus
        connectionChanged?(newStatus)
    }

    private func finishTimeoutIfNeeded() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state != .poweredOn {
                connecting = false
                setStatus(.unauthorized)
                return
            }

            connecting = true
            setStatus(.connecting)

            timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                // Avoid capturing main-actor-isolated 'self' directly in a @Sendable context.
                guard let strongSelf = self else { return }
                let controller = strongSelf
                Task { @MainActor in
                    controller.setStatus(.disconnected)
                    controller.central?.stopScan()
                    controller.connecting = false
                }
            }

            central.scanForPeripherals(
                withServices: [bleServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            central.stopScan()
            finishTimeoutIfNeeded()

            peripheral.delegate = self
            self.myPeripheral = peripheral

            self.central?.connect(peripheral, options: nil)

            token = peripheral.observe(\.state) { [weak self] object, _ in
                guard let self else { return }
                Task { @MainActor in
                    switch object.state {
                    case .connecting:
                        self.connecting = true
                        self.setStatus(.connecting)
                    case .connected:
                        self.connecting = false
                        self.setStatus(.connected)
                    case .disconnecting:
                        self.connecting = false
                        self.setStatus(.disconnecting)
                    case .disconnected:
                        self.connecting = false
                        self.setStatus(.disconnected)
                    default:
                        break
                    }
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard peripheral == self.myPeripheral else { return }
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if peripheral == self.myPeripheral {
                self.txCharacteristic = nil
                self.rxCharacteristic = nil
                self.finishTimeoutIfNeeded()
                self.connecting = false
                self.setStatus(.disconnected)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard let services = peripheral.services else { return }

            for service in services where service.uuid == bleServiceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
                return
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil else { return }
            guard let characteristics = service.characteristics, !characteristics.isEmpty else { return }

            // Find TX (notify/read) and RX (write) characteristics by UUID.
            let foundTx = characteristics.first(where: { $0.uuid == bleTxCharacteristicUUID })
            let foundRx = characteristics.first(where: { $0.uuid == bleRxCharacteristicUUID })

            if let foundTx {
                txCharacteristic = foundTx
                print("Found TX characteristic:", foundTx.uuid.uuidString, "props:", foundTx.properties)
                // Subscribe for notifications from peripheral -> iOS
                peripheral.setNotifyValue(true, for: foundTx)
            }

            if let foundRx {
                rxCharacteristic = foundRx
                print("Found RX characteristic:", foundRx.uuid.uuidString, "props:", foundRx.properties)
            }

            // If we didn't find them by UUID, fall back to properties-based selection (helps when UUIDs differ).
            if txCharacteristic == nil {
                if let candidate = characteristics.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }) {
                    txCharacteristic = candidate
                    print("Fallback TX characteristic:", candidate.uuid.uuidString, "props:", candidate.properties)
                    peripheral.setNotifyValue(true, for: candidate)
                }
            }

            if rxCharacteristic == nil {
                if let candidate = characteristics.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
                    rxCharacteristic = candidate
                    print("Fallback RX characteristic:", candidate.uuid.uuidString, "props:", candidate.properties)
                }
            }

            if txCharacteristic == nil || rxCharacteristic == nil {
                print("Warning: Missing TX or RX characteristic.", "TX:", txCharacteristic as Any, "RX:", rxCharacteristic as Any)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            hasUpdated = true

            // Only treat incoming data from the TX characteristic as sensor/telemetry.
            if let tx = txCharacteristic, characteristic.uuid != tx.uuid {
                return
            }

            guard error == nil else {
                characteristicDidUpdateValue?(false, characteristic.value)
                return
            }

            guard let data = characteristic.value else {
                characteristicDidUpdateValue?(false, nil)
                return
            }

            lastRawData = data
            characteristicDidUpdateValue?(true, data)

            // Your original parsing: string -> split by ">" -> take [0] -> Float
            if let dataString = String(data: data, encoding: .utf8) {
                let parts = dataString.components(separatedBy: ">")
                let value = Float(parts.first ?? "") ?? 0.0

                lastArduinoValue = value
                arduinoData?(value)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            hasUpdated = true
            if let error {
                print("Notify state error:", error)
            } else {
                print("Notify state updated for:", characteristic.uuid.uuidString, "isNotifying:", characteristic.isNotifying)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            // Only care about responses for RX writes.
            if let rx = rxCharacteristic, characteristic.uuid != rx.uuid {
                return
            }

            hasUpdated = true

            if let error {
                print("Write error (RX):", error)
            } else {
                print("Write success (RX)")
            }
        }
    }
}
