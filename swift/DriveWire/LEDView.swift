//
//  LED.swift
//  DriveWire
//
//  Created by Boisy Pitre on 3/23/24.
//

import SwiftUI

struct LEDView: View {
    var isOn: Bool = true
    var activeColor: Color = .red

    var body: some View {
        Circle()
            .fill(isOn ? activeColor : Color.secondary.opacity(0.25))
            .overlay(
                Circle()
                    .strokeBorder(isOn ? activeColor.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 4)
            )
            .shadow(color: isOn ? activeColor.opacity(0.35) : .clear, radius: 4)
            .accessibilityHidden(true)
    }
}
