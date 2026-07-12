//
//  AutoCaptionView+Form.swift
//  Strophe
//
//  Shared form support. Platform-specific views live in FormMac.swift and
//  FormIOS.swift; keeping them out of this file prevents synchronized Xcode
//  groups from compiling duplicate declarations into the iOS target.
//

import SwiftUI

extension AutoCaptionView {
    var coreMLASRAccelerationBinding: Binding<Bool> {
        Binding(
            get: {
                enableCoreMLASRAcceleration
                    && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel)
            },
            set: { newValue in
                enableCoreMLASRAcceleration = newValue
            }
        )
    }
}
