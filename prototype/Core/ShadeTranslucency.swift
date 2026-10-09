// 收起后留下的东西（卷帘条或缩略图）透多少：设置里的一个滑块，0 = 不透明，最多 70%。
//
// 原来只有“卷帘条半透明”一个开关，打开时透 18%（不透明度 0.82）。没拖过滑块时按老开关算，
// 升级后样子不变；拖过滑块后以滑块为准，同时写老开关（大于 0 算打开），回到旧版本时样子也最接近。
// 设置里还有老开关时，拨它照样生效：滑块每次都把两个设置写成一致，两者对不上就说明之后拨过老开关，
// 按老开关算；拨回到和滑块一致时，又按滑块的数值算。

import Foundation

enum ShadeTranslucency {
    /// 滑块的数值（0…maximum，透明的比例）。
    static let defaultsKey = "ShadeTranslucency"
    /// 老开关（WindowShade.swift 的 shadeTranslucentDefaultsKey）。
    static let legacyDefaultsKey = "ShadeTranslucent"
    /// 老开关打开时透的比例：不透明度 0.82（shadeTranslucentAlpha）。
    static let legacyFraction: Double = 0.18
    static let maximum: Double = 0.7

    /// 现在透多少。没拖过滑块时按老开关算；拖过以后又拨了老开关（两者对不上）时，也按老开关算。
    static func fraction(in defaults: UserDefaults = .standard) -> Double {
        let legacyOn = defaults.bool(forKey: legacyDefaultsKey)
        if let stored = defaults.object(forKey: defaultsKey) as? NSNumber {
            let value = clamp(stored.doubleValue)
            if (value > 0.001) == legacyOn { return value }
        }
        return legacyOn ? legacyFraction : 0
    }

    /// 拖滑块：存新数值，老开关跟着写。返回存下的数值（夹在 0…maximum）。
    @discardableResult
    static func set(_ value: Double, in defaults: UserDefaults = .standard) -> Double {
        let clamped = clamp(value)
        defaults.set(clamped, forKey: defaultsKey)
        defaults.set(clamped > 0.001, forKey: legacyDefaultsKey)
        return clamped
    }

    /// 窗口的不透明度（alphaValue）。
    static func opacity(in defaults: UserDefaults = .standard) -> Double {
        1 - fraction(in: defaults)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(maximum, max(0, value))
    }
}
