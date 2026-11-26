import Foundation
import UIKit

enum CategoryIconDescriptor: Equatable {
    case systemSymbol(String)
    case text(String)
}

enum CategoryIconLibrary {
    struct Group: Identifiable {
        let title: String
        let symbols: [String]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "餐饮", symbols: [
            "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "birthday.cake",
            "sunrise", "apple.logo", "basket"
        ]),
        Group(title: "交通", symbols: [
            "car", "bus", "tram", "bicycle", "airplane", "fuelpump",
            "parkingsign.circle", "road.lanes", "wrench.and.screwdriver"
        ]),
        Group(title: "购物", symbols: [
            "bag", "cart", "tshirt", "gift", "desktopcomputer", "sofa", "laptopcomputer", "comb",
            "camera", "smartphone"
        ]),
        Group(title: "居住", symbols: [
            "house", "bed.double", "lightbulb", "washer", "bolt.house", "building.2", "wifi",
            "house.lodge", "building.columns"
        ]),
        Group(title: "医疗", symbols: [
            "cross.case", "pills", "heart.text.clipboard", "heart", "shield.checkered"
        ]),
        Group(title: "娱乐", symbols: [
            "gamecontroller", "film", "music.note", "sportscourt", "figure.run",
            "person.3", "paintpalette", "rectangle.stack.badge.play", "headphones", "theatermasks",
            "dumbbell", "figure.outdoor.cycle"
        ]),
        Group(title: "学习", symbols: [
            "book", "graduationcap", "pencil.and.ruler", "printer", "briefcase"
        ]),
        Group(title: "家庭与旅行", symbols: [
            "person.2", "figure.2.and.child.holdinghands", "suitcase.rolling", "map",
            "envelope", "ticket", "pawprint", "scissors", "person.2.circle", "giftcard",
            "shippingbox", "binoculars", "globe.asia.australia"
        ]),
        Group(title: "收入", symbols: [
            "banknote", "briefcase", "chart.line.uptrend.xyaxis", "plus.circle", "doc.text",
            "clock.arrow.circlepath", "percent", "chart.pie", "arrow.uturn.backward.circle",
            "creditcard", "repeat.circle"
        ]),
        Group(title: "其他", symbols: [
            "square.grid.2x2", "ellipsis.circle", "star", "tag", "leaf", "wineglass", "carrot", "arrow.left.arrow.right"
        ])
    ]

    static let fallback = "square.grid.2x2"
    static let allSymbols = Set(groups.flatMap(\.symbols))

    static func descriptor(for storedValue: String) -> CategoryIconDescriptor {
        if let text = textIconText(from: storedValue) {
            return .text(text)
        }
        return .systemSymbol(safeSymbol(storedValue))
    }

    static func safeSymbol(_ symbol: String) -> String {
        allSymbols.contains(symbol) ? symbol : fallback
    }

    static func availableSymbol(_ symbol: String) -> String {
        let safe = safeSymbol(symbol)
        return UIImage(systemName: safe) == nil ? fallback : safe
    }

    static func normalizedStoredValue(_ value: String) -> String? {
        if allSymbols.contains(value) {
            return value
        }
        return textIconText(from: value).map { "text:\($0)" }
    }

    static func isValidStoredIcon(_ value: String) -> Bool {
        normalizedStoredValue(value) != nil
    }

    static func textIconText(from value: String) -> String? {
        guard value.hasPrefix("text:") else { return nil }
        let text = String(value.dropFirst("text:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(text)
        guard !characters.isEmpty, characters.count <= 2 else { return nil }
        return String(characters)
    }

    static func textIconValue(from text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(normalized)
        guard !characters.isEmpty, characters.count <= 2 else { return nil }
        return "text:\(String(characters))"
    }

    static func synchronizedTextIconValue(
        currentValue: String,
        followsCategoryName: Bool,
        categoryName: String
    ) -> String {
        guard followsCategoryName else { return currentValue }
        return textIconValue(from: String(
            categoryName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)
        )) ?? "text:"
    }

    static func suggestedSymbol(for name: String, kind: CategoryKind) -> String {
        let rules: [(String, String)] = [
            ("餐", "fork.knife"), ("饭", "fork.knife"), ("咖啡", "cup.and.saucer"),
            ("车", "car"), ("交通", "bus"), ("地铁", "tram"), ("机票", "airplane"),
            ("购物", "bag"), ("衣", "tshirt"), ("房", "house"), ("租", "house"),
            ("医", "cross.case"), ("药", "pills"), ("游戏", "gamecontroller"),
            ("电影", "film"), ("书", "book"), ("学习", "graduationcap"),
            ("旅行", "suitcase.rolling"), ("家庭", "person.2"), ("礼", "gift"),
            ("薪", "banknote"), ("工资", "banknote"), ("奖金", "gift"), ("理财", "chart.line.uptrend.xyaxis")
        ]
        return rules.first(where: { name.localizedCaseInsensitiveContains($0.0) })?.1
            ?? (kind == .income ? "plus.circle" : fallback)
    }
}
