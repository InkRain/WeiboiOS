import Foundation

/// 微博接口的 JSON 结构极不稳定，字段时有时无、类型时字符串时数字。
/// 这里提供一层与 Kotlin 版 `JSONObject.opt*` 语义一致的防御式访问器，
/// 让上层解析代码不必到处写 if let / as?。
struct JSONValue {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }

    static let null = JSONValue(nil)

    // MARK: - 解析

    static func parse(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            throw WeiboError.invalidResponse("响应内容为空")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> JSONValue {
        if let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           trimmed.hasPrefix("<") {
            throw WeiboError.htmlResponse
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return JSONValue(object)
        } catch {
            throw WeiboError.invalidResponse("无法解析接口返回内容")
        }
    }

    // MARK: - 基础取值

    var isNull: Bool {
        guard let value else { return true }
        return value is NSNull
    }

    var exists: Bool { !isNull }

    var string: String? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "1" : "0"
            }
            return n.stringValue
        case let d as Double:
            return d == d.rounded() ? String(Int64(d)) : String(d)
        case let i as Int:
            return String(i)
        default:
            return nil
        }
    }

    /// 空字符串按「不存在」处理，微博常用 "" 表示缺失。
    var nonEmptyString: String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    var int: Int? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    var int64: Int64? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var double: Double? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var bool: Bool {
        guard let value, !(value is NSNull) else { return false }
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.intValue != 0
        case let s as String:
            let t = s.lowercased()
            return t == "1" || t == "true" || t == "yes"
        default:
            return false
        }
    }

    var array: [JSONValue] {
        guard let list = value as? [Any] else { return [] }
        return list.map { JSONValue($0) }
    }

    var object: JSONValue? {
        guard let dict = value as? [String: Any] else { return nil }
        return JSONValue(dict)
    }

    var dictionaryKeys: [String] {
        (value as? [String: Any])?.keys.map { $0 } ?? []
    }

    // MARK: - 键访问

    subscript(key: String) -> JSONValue {
        guard let dict = value as? [String: Any] else { return .null }
        return JSONValue(dict[key])
    }

    /// 依次尝试多个键，返回第一个非空字符串（按 Kotlin 版 `?:` 链写法）。
    func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let s = self[key].nonEmptyString { return s }
        }
        return nil
    }

    func firstInt(_ keys: String...) -> Int? {
        for key in keys {
            if let i = self[key].int { return i }
        }
        return nil
    }

    func firstDouble(_ keys: String...) -> Double? {
        for key in keys {
            if let d = self[key].double { return d }
        }
        return nil
    }

    func objectOrNil(_ key: String) -> JSONValue? {
        self[key].object
    }

    var prettyPrinted: String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value ?? "nil")
        }
        return text
    }
}

// MARK: - 错误

enum WeiboError: LocalizedError {
    case notLoggedIn
    case htmlResponse
    case http(Int, String)
    case invalidResponse(String)
    case api(String)
    case canceled

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "未发现微博登录状态，请先在「我的 → 账号管理」完成登录"
        case .htmlResponse:
            return "微博返回了网页而不是数据，登录可能已失效，请重新登录"
        case let .http(code, detail):
            if code == 418 || code == 403 {
                return "微博拒绝了这次请求（\(code)），请稍后重试或重新登录"
            }
            if code == 404 {
                return "内容不存在或已被删除"
            }
            return detail.isEmpty ? "网络请求失败（\(code)）" : "网络请求失败（\(code)）：\(detail)"
        case let .invalidResponse(message):
            return message
        case let .api(message):
            return message
        case .canceled:
            return "已取消"
        }
    }
}
