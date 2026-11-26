import Foundation

struct SmartClassificationRule: Sendable {
    let kind: CategoryKind
    let rootName: String
    let childName: String
    let keywords: [String]
    let exclusions: [String]
    let score: Int

    init(
        kind: CategoryKind,
        rootName: String,
        childName: String,
        keywords: [String],
        exclusions: [String] = [],
        score: Int = 92
    ) {
        self.kind = kind
        self.rootName = rootName
        self.childName = childName
        self.keywords = keywords
        self.exclusions = exclusions
        self.score = score
    }
}

enum SmartClassificationLexicon {
    static let rules: [SmartClassificationRule] = [
        expense("餐饮", "早餐", ["豆浆油条", "买包子", "早餐", "早饭"]),
        expense("餐饮", "午餐", ["公司午饭", "工作餐", "午餐", "午饭"]),
        expense("餐饮", "晚餐", ["晚饭火锅", "晚餐", "晚饭", "火锅"]),
        expense("餐饮", "外卖零食", ["美团外卖", "饿了么", "买薯片", "外卖", "零食"]),
        expense(
            "餐饮",
            "水果",
            ["火龙果", "买水果", "水果", "香蕉", "橙子", "苹果"],
            exclusions: ["苹果手机", "苹果电脑", "苹果手表"]
        ),
        expense(
            "餐饮",
            "咖啡奶茶",
            ["星巴克", "瑞幸", "奶茶", "咖啡"],
            exclusions: ["咖啡机", "咖啡杯", "奶茶色"]
        ),
        expense("餐饮", "买菜食材", ["超市买菜", "鸡蛋青菜", "买菜", "食材", "菜市场"]),

        expense("交通", "公交", ["公交卡", "坐公交", "公交车", "公交"]),
        expense("交通", "地铁", ["地铁通勤", "坐地铁", "地铁"]),
        expense("交通", "打车", ["滴滴", "网约车", "出租车", "打车"]),
        expense("交通", "加油", ["中石化加油", "中石油", "加油站", "加油"]),
        expense("交通", "停车", ["停车费", "停车场", "停车"]),
        expense("交通", "高速过路", ["高速费", "过路费", "etc"]),
        expense("交通", "维修保养", ["保养汽车", "换机油", "汽车维修", "车辆保养"]),

        expense("购物", "日用品", ["纸巾牙膏", "日用品", "洗衣液", "卫生纸", "牙膏"]),
        expense("购物", "服饰鞋包", ["买鞋", "外套", "裤子", "衣服", "鞋包"]),
        expense("购物", "数码", ["电脑配件", "耳机", "手机", "数码"]),
        expense("购物", "家居", ["床单", "沙发", "灯具", "家居", "家具"]),
        expense("购物", "婴幼儿养护", ["纸尿裤", "尿不湿", "奶粉", "婴儿用品"]),
        expense("购物", "美妆护肤", ["防晒", "面霜", "口红", "护肤", "化妆品"]),
        expense("购物", "礼物", ["生日礼物", "买礼物", "伴手礼"]),

        expense("居家", "房租房贷", ["交房租", "还房贷", "房租", "房贷"]),
        expense("居家", "水电燃气", ["水费", "电费", "燃气费", "天然气费"]),
        expense("居家", "物业", ["物业费", "物业管理费"]),
        expense("居家", "通讯网络", ["手机流量", "宽带", "话费", "网费"]),
        expense("居家", "家政维修", ["修水管", "家政", "保洁", "开锁", "上门维修"]),

        expense("医疗教育", "医疗药品", ["感冒药", "药店", "挂号", "看病", "药品"]),
        expense("医疗教育", "体检", ["年度体检", "健康体检", "体检"]),
        expense("医疗教育", "保健", ["维生素", "保健品", "营养补充剂"]),
        expense("医疗教育", "学习课程", ["英语课", "培训班", "学习课程", "网课", "学费"]),
        expense("医疗教育", "书籍文具", ["买书", "文具", "书籍", "笔记本"]),

        expense("娱乐", "电影演出", ["电影票", "演唱会", "话剧", "演出票"]),
        expense("娱乐", "游戏", ["游戏充值", "买游戏", "游戏点卡"]),
        expense("娱乐", "运动", ["羽毛球", "健身房", "游泳", "运动"]),
        expense("娱乐", "聚会", ["朋友聚餐", "同学会", "朋友聚会", "团建聚会"]),
        expense(
            "娱乐",
            "兴趣爱好",
            ["摄影器材", "乐器", "手办", "模型", "兴趣爱好"],
            exclusions: ["摄影课程", "摄影培训"]
        ),
        expense("娱乐", "会员订阅", ["视频会员", "音乐会员", "会员订阅", "爱奇艺会员"]),

        expense("人情", "红包", ["发红包", "给红包"]),
        expense("人情", "礼金", ["婚礼礼金", "送礼金", "随礼"]),
        expense("人情", "孝敬长辈", ["给父母生活费", "孝敬长辈", "父母生活费"]),

        expense("旅行", "住宿", ["旅行酒店", "旅行民宿", "酒店", "民宿"]),
        expense("旅行", "门票", ["景区门票", "旅游门票", "景点门票"]),
        expense("旅行", "旅行交通", ["旅行火车票", "旅行高铁票", "出游火车票", "机票"]),
        expense("旅行", "旅行交通", ["火车票", "高铁票"], score: 68),
        expense("旅行", "旅行餐饮", ["旅行吃饭", "旅行餐饮", "旅途中吃饭"]),
        expense("旅行", "旅行购物", ["旅行买纪念品", "旅行购物", "旅游纪念品"]),

        income("工作收入", "工资", ["工资到账", "发工资", "工资"]),
        income("工作收入", "奖金", ["年终奖", "季度奖金", "奖金"]),
        income("工作收入", "报销", ["公司报销", "报销到账", "报销"]),
        income("工作收入", "兼职", ["兼职收入", "兼职工资", "兼职"]),

        income("理财收入", "利息", ["银行利息", "存款利息", "利息"]),
        income("理财收入", "分红", ["基金分红", "股票分红", "分红"]),
        income("理财收入", "投资收益", ["股票收益", "投资收益", "基金收益"]),

        income("其他收入", "退款", ["退款到账", "收到退款", "退款"]),
        income("其他收入", "红包", ["收到红包", "红包收入"]),
        income("其他收入", "礼金", ["收到礼金", "礼金收入"])
    ]

    static var coveredPaths: Set<String> {
        Set(rules.map { "\($0.kind.rawValue)|\($0.rootName)|\($0.childName)" })
    }

    private static func expense(
        _ root: String,
        _ child: String,
        _ keywords: [String],
        exclusions: [String] = [],
        score: Int = 92
    ) -> SmartClassificationRule {
        SmartClassificationRule(
            kind: .expense,
            rootName: root,
            childName: child,
            keywords: keywords,
            exclusions: exclusions,
            score: score
        )
    }

    private static func income(
        _ root: String,
        _ child: String,
        _ keywords: [String],
        exclusions: [String] = [],
        score: Int = 92
    ) -> SmartClassificationRule {
        SmartClassificationRule(
            kind: .income,
            rootName: root,
            childName: child,
            keywords: keywords,
            exclusions: exclusions,
            score: score
        )
    }
}
