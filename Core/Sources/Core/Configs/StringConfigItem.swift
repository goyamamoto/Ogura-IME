//
//  StringConfigItem.swift
//  Ogura
//
//  Created by miwa on 2024/04/27.
//

import Foundation

protocol StringConfigItem: ConfigItem<String> {}

extension StringConfigItem {
    public var value: String {
        get {
            Config.string(forKey: Self.key) ?? ""
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiProfile: StringConfigItem {
        public init() {}

        public static let key: String = "org.if0.inputmethod.ogura.preference.ZenzaiProfile"
    }
}

extension Config {
}
