//
//  ContentView.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import SwiftUI
import ORSSerial

struct VirtualChannelView : View {
    var channelNumber : Int
    var body : some View {
        HStack {
            Label("Channel \(channelNumber)", systemImage: "")
            LEDView()
        }
    }
}

struct VirtualChannelsView : View {
    var body : some View {
        GroupBox(label:
                    Label("Virtual Serial Channels", systemImage:
                            "bolt.horizontal.fill")
        ) {
            ScrollView {
                VirtualChannelView(channelNumber: 0)
                VirtualChannelView(channelNumber: 1)
                VirtualChannelView(channelNumber: 2)
                VirtualChannelView(channelNumber: 3)
                VirtualChannelView(channelNumber: 4)
                VirtualChannelView(channelNumber: 5)
                VirtualChannelView(channelNumber: 6)
                VirtualChannelView(channelNumber: 7)
            }
        }.padding(10)
    }
}

struct DriveSelector: View {
    let buttonSize = 40.0
    @Binding var selectedDisk : String
    var body: some View {
        HStack {
            Button(action: {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    self.selectedDisk = panel.url?.relativePath ?? "<none>"
                }
            }) {
                Image(systemName: "externaldrive")
            }.frame(width: buttonSize, height: buttonSize)
                .font(.system(size: buttonSize * 0.7))
                .foregroundColor(Color.white)
                .background(Color.blue)
                .cornerRadius(buttonSize / 6.0)
                .buttonStyle(PlainButtonStyle())
            VStack {
                TextField("Disk Image", text: $selectedDisk).padding(10)
            }
        }
    }
}

struct SerialPortSelector: View {
     @Binding var selectedPortName : String
     @Binding var selectedBaudRate : String
     
     var body: some View {
         VStack {
             Picker("Serial port:", selection: $selectedPortName) {
                 Text("No device").tag("---")
                 ForEach(ObservableSerialPortManager().availablePorts, id: \.self) { port in
                     Text(port.name).tag(port.name)
                 }
             }
             Picker("Baud rate:", selection: $selectedBaudRate) {
                 ForEach(["57600", "115200", "230400"], id: \.self) { baud in
                     Text(baud).tag(baud)
                 }
             }
        }
    }
}

struct IPAddressSelector: View {
    @Binding var selectedIPAddress : String
    @Binding var selectedIPPort : String
    let labelWidth = 80.0
    
     var body: some View {
         VStack {
             HStack {
                 Text("IP Address:").frame(width: labelWidth, alignment: .trailing)
                 TextField("", text: $selectedIPAddress)
             }
             HStack {
                 Text("IP Port:").frame(width: labelWidth, alignment: .trailing)
                 TextField("", text: $selectedIPPort)
             }
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var document: DriveWireDocument

     var body: some View {
         VStack {
             let labelWidth = 100.0
             HStack {
                 HStack {
                     Text("Last Opcode:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.lastOpCode, formatter: NumberFormatter())
                 }
                 HStack {
                     Text("Last LSN:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.lastLSN, formatter: NumberFormatter())
                 }
             }
             HStack {
                 HStack {
                     Text("Sectors Read:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.readCount, formatter: NumberFormatter())
                 }
                 HStack {
                     Text("Sectors Written:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.writeCount, formatter: NumberFormatter())
                 }
             }
             HStack {
                 HStack {
                     Text("Last GetStat:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.lastGetStat, formatter: NumberFormatter())
                 }
                 HStack {
                     Text("Last SetStat:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.lastSetStat, formatter: NumberFormatter())
                 }
             }
             HStack {
                 HStack {
                     Text("Read Retries:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.reReadCount, formatter: NumberFormatter())
                 }
                 HStack {
                     Text("Write Retries:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.reWriteCount, formatter: NumberFormatter())
                 }
             }
             HStack {
                 HStack {
                     Text("% Reads OK:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.percentReadsOK, formatter: NumberFormatter())
                 }
                 HStack {
                     Text("% Writes OK:").frame(width: labelWidth, alignment: .trailing)
                     TextField("", value: $document.serialDriver.host.statistics.percentWritesOK, formatter: NumberFormatter())
                 }
             }
         }
    }
}

struct SerialCommsView : View {
    @ObservedObject var document: DriveWireDocument
    @Binding var portName: String
    @Binding var baudRate: String

    var body: some View {
        SerialPortSelector(selectedPortName: $portName, selectedBaudRate: $baudRate).onChange(of: portName) { oldValue, newValue in
            document.serialDriver.portName = newValue
        }.onChange(of: baudRate) { oldValue, newValue in
            document.serialDriver.baudRate = Int(newValue)!
        }.onDisappear(perform: {
            document.serialDriver.stop()
        }).onAppear(perform: {
            portName = document.serialDriver.portName
            baudRate = String(document.serialDriver.baudRate)
        }).padding(10)
    }
}

struct TCPCommsView : View {
    @ObservedObject var document: DriveWireDocument
    @Binding var ipAddress: String
    @Binding var ipPort: String

    var body: some View {
        IPAddressSelector(selectedIPAddress: $ipAddress, selectedIPPort: $ipPort)
    }
}

struct ContentView: View {
    @ObservedObject var document: DriveWireDocument
    @State var selectedName = "---"
    @State var selectedBaud = "57600"
    @State var selectedIPAddress = "192.168.0.10"
    @State var selectedIPPort = "6809"
    @State var selectedDisk0 = ""
    @State var selectedDisk1 = ""
    @State var selectedDisk2 = ""
    @State var selectedDisk3 = ""

    var body: some View {
        HStack {
            GroupBox(label:
                        Label("Disks", systemImage: "externaldrive")
            ) {
                HStack {
                    VStack {
                        let drives: [DriveSelector] = [
                            DriveSelector(selectedDisk: $selectedDisk0),
                            DriveSelector(selectedDisk: $selectedDisk1),
                            DriveSelector(selectedDisk: $selectedDisk2),
                            DriveSelector(selectedDisk: $selectedDisk3)
                        ]
                        
                        drives[0]
                            .onChange(of: selectedDisk0) { oldValue, newValue in
                                do {
                                    try document.serialDriver.host.insertVirtualDisk(driveNumber: 0, imagePath: newValue)
                                } catch {
                                    
                                }
                            }.onAppear(perform: {
                                if document.serialDriver.host.virtualDrives.count > 0 {
                                    let diskName = document.serialDriver.host.virtualDrives[0].imagePath
                                    selectedDisk0 = diskName
                                }
                            })
                        
                        drives[1]
                            .onChange(of: selectedDisk1) { oldValue, newValue in
                                do {
                                    try document.serialDriver.host.insertVirtualDisk(driveNumber: 1, imagePath: newValue)
                                } catch {
                                }
                            }
                    }
                }
            }.padding(10)
            GroupBox(label:
                Label("Statistics", systemImage: "building.columns")
            ) {
                StatisticsView(document: document)
            }.padding(10)
        }

        HStack{
            GroupBox(label:
                Label("Communication", systemImage: "list.bullet")
            ) {
                Picker("Connection Type", selection: $document.connectionType) {
                    ForEach(DriveWireDocument.ConnectionType.allCases) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .pickerStyle(.radioGroup)

                if document.connectionType == .serial {
                    // Show serial UI
                    SerialCommsView(document: document, portName: $selectedName, baudRate: $selectedBaud)
                } else {
                    // Show TCP/IP UI
                    TCPCommsView(document: document, ipAddress: $selectedIPAddress, ipPort: $selectedIPPort)
                }
            }

            VirtualChannelsView().padding(10)

        }.padding(10)
        
        GroupBox(label:
            Label("Logging", systemImage: "list.bullet")
        ) {
            TextEditor(text: $document.serialDriver.host.log)
        }.padding(10)
        
    }
}

class ObservableSerialPortManager: ObservableObject {
    @Published var availablePorts: [ORSSerialPort] = []
    private var portManager: ORSSerialPortManager

    init() {
        portManager = ORSSerialPortManager.shared()
        
        NotificationCenter.default.addObserver(self, selector: #selector(portsWereConnected(_:)), name: Notification.Name.ORSSerialPortsWereConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(portsWereDisconnected(_:)), name: Notification.Name.ORSSerialPortsWereDisconnected, object: nil)

        updateAvailablePorts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func portsWereConnected(_ notification: Notification) {
        updateAvailablePorts()
    }

    @objc private func portsWereDisconnected(_ notification: Notification) {
        updateAvailablePorts()
    }

    private func updateAvailablePorts() {
        availablePorts = portManager.availablePorts as [ORSSerialPort]
    }
}


 #Preview {
    ContentView(document: DriveWireDocument())
}
