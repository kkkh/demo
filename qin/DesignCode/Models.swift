//
//  Models.swift
//  山西晋中理工学院 APP — 数据模型与静态兜底数据
//

import Foundation

// MARK: - 学校信息

enum SchoolInfo {
    static let name = "山西晋中理工学院"
    static let englishName = "Shanxi Jinzhong Institute of Technology"
    static let motto = "谨信博学 · 经世致用"
    static let address = "山西省晋中市榆次区创业街839号"
    static let foundedYear = "2002"
    static let convertedYear = "2021"
    static let anniversary = "10月9日"
    static let type = "民办全日制普通本科"
    static let affiliation = "山西省教育厅"
    static let predecessor = "中北大学信息商务学院"
    static let website = "https://www.sxjzit.edu.cn"
    static let phone = "0351-3624911"
    static let recruitPhones = ["0351-3624910", "0351-3624912", "0351-3624902"]
    static let email = "sxjzlgxydwxcb@163.com"
    static let postalCode = "030600"
    static let campusArea = "1000余亩"
    static let buildingArea = "33万平方米"
    static let libraryBooks = "120余万册"
    static let teachingInstruments = "总值9000余万元"
    static let studentCount = "16945"
    static let majorCount = "44"
    static let departmentCount = "10"
    static let description = """
    山西晋中理工学院（原中北大学信息商务学院），是经教育部批准设立的全日制普通本科院校。学校位于山西省晋中市榆次区，占地面积1000余亩，建筑面积33万平方米。学校设有10个教学机构，开设44个本科专业，涵盖工学、经济学、管理学、法学、文学、艺术学等多个学科门类，在校生16945人。

    学校坚持"谨信博学、经世致用"的校训，秉承"以学生为中心"的办学理念，致力于培养高素质应用型人才。学校拥有完善的教学设施和实验实训条件，图书馆藏书120余万册，教学科研仪器设备总值9000余万元。

    2021年2月，经教育部批准，中北大学信息商务学院转设为独立设置的民办普通本科高校——山西晋中理工学院。2025年，学校位列校友会中国民办大学排名（山西省）第1名。
    """
}

// MARK: - Banner

struct Banner: Identifiable, Codable {
    var id: String { videoSrc }
    let videoSrc: String
    let posterImgSrc: String
    let videoTitleImgSrc: String
}

let defaultBanners: [Banner] = [
    Banner(videoSrc: "https://www.sxjzit.edu.cn/banner/video1.mp4",
           posterImgSrc: "https://www.sxjzit.edu.cn/banner/poster1.jpg",
           videoTitleImgSrc: "https://www.sxjzit.edu.cn/banner/title1.png"),
    Banner(videoSrc: "https://www.sxjzit.edu.cn/banner/video2.mp4",
           posterImgSrc: "https://www.sxjzit.edu.cn/banner/poster2.jpg",
           videoTitleImgSrc: "https://www.sxjzit.edu.cn/banner/title2.png"),
    Banner(videoSrc: "https://www.sxjzit.edu.cn/banner/video3.mp4",
           posterImgSrc: "https://www.sxjzit.edu.cn/banner/poster3.jpg",
           videoTitleImgSrc: "https://www.sxjzit.edu.cn/banner/title3.png"),
]

// MARK: - 统计项

struct StatItem: Identifiable, Codable {
    var id: String { value + label }
    let value: String
    let label: String
    let icon: String
}

let defaultStats: [StatItem] = [
    StatItem(value: "44", label: "本科专业", icon: "book.closed.fill"),
    StatItem(value: "10", label: "教学机构", icon: "building.2.fill"),
    StatItem(value: "16945", label: "在校学生", icon: "person.3.fill"),
    StatItem(value: "100+", label: "校企合作", icon: "briefcase.fill"),
]

// MARK: - 荣誉

struct Honor: Identifiable, Codable {
    var id: String { articleId ?? title }
    let title: String
    let detail: String
    let icon: String
    let imageUrl: String?
    let tag: String?
    let date: String?
    var articleId: String? = nil

    init(title: String, detail: String, icon: String, imageUrl: String? = nil, tag: String? = nil, date: String? = nil, articleId: String? = nil) {
        self.title = title; self.detail = detail; self.icon = icon
        self.imageUrl = imageUrl; self.tag = tag; self.date = date; self.articleId = articleId
    }
}

let defaultHonors: [Honor] = [
    Honor(title: "山西省民办大学第1名", detail: "校友会2025中国大学排名", icon: "medal.fill", tag: "2025"),
    Honor(title: "全国理工类民办第53", detail: "校友会2025中国大学排名", icon: "rosette", tag: "2025"),
    Honor(title: "中国应用型大学", detail: "校友会分类体系", icon: "star.fill", tag: "认证"),
    Honor(title: "电子与计算机工程全国第9", detail: "软科2025中国大学专业排名", icon: "star.circle.fill", tag: "软科排名"),
    Honor(title: "虚拟现实技术全国第18", detail: "软科2025中国大学专业排名", icon: "sparkles", tag: "软科排名"),
    Honor(title: "全国健康学校", detail: "2023年教育部首批建设单位", icon: "heart.fill", tag: "教育部"),
    Honor(title: "互联网金融全国第32", detail: "软科2025中国大学专业排名", icon: "chart.line.uptrend.xyaxis", tag: "软科排名"),
    Honor(title: "山西省平安校园", detail: "山西省教育厅、公安厅联合授予", icon: "shield.checkered", tag: "省级"),
    Honor(title: "山西省文明校园", detail: "山西省精神文明建设指导委员会", icon: "building.columns.fill", tag: "省级"),
    Honor(title: "全国大学生竞赛优秀组织奖", detail: "中国高等教育学会", icon: "trophy.fill", tag: "国家级"),
    Honor(title: "山西省高校毕业生就业工作先进单位", detail: "连续多年获评就业工作先进单位", icon: "person.crop.circle.badge.checkmark", tag: "省级"),
    Honor(title: "山西省高校党建工作示范单位", detail: "中共山西省委教育工委", icon: "flag.fill", tag: "党建"),
]

// MARK: - 院系

struct Department: Identifiable, Codable {
    var id: String { name }
    let name: String
    let englishName: String
    let icon: String
    let intro: String
    let siteKey: String?
    var subDepartments: [String]
    var majors: [Major]

    init(name: String, englishName: String, icon: String, intro: String, siteKey: String? = nil, subDepartments: [String] = [], majors: [Major] = []) {
        self.name = name; self.englishName = englishName; self.icon = icon
        self.intro = intro; self.siteKey = siteKey
        self.subDepartments = subDepartments; self.majors = majors
    }
}

struct Major: Identifiable, Codable {
    var id: String { name }
    let name: String
    let category: String
    let duration: String
    let intro: String
    let career: String
}

let defaultDepartments: [Department] = [
    Department(
        name: "信创与大数据学院",
        englishName: "School of IT & Big Data",
        icon: "cpu.fill",
        intro: "信创与大数据学院是学校信息技术人才培养的核心基地，下设电子信息工程系、大数据与智能工程系两个系部，共开设13个本科专业，涵盖计算机、电子信息、物联网、人工智能等前沿领域。学院拥有智能硬件云平台实验中心等先进教学设施，注重信创产业与大数据技术的深度融合，培养适应数字经济发展需求的高素质应用型人才。",
        siteKey: "xcdsj",
        subDepartments: ["电子信息工程系", "大数据与智能工程系"],
        majors: [
            Major(name: "计算机科学与技术", category: "工学", duration: "四年制本科",
                  intro: "培养计算机软硬件系统设计与开发的高级人才，设有云计算方向和大数据方向两个特色培养方向。",
                  career: "软件工程师、算法工程师、系统架构师、云计算工程师等"),
            Major(name: "网络工程", category: "工学", duration: "四年制本科",
                  intro: "培养网络规划、设计、管理与安全方面的工程技术人才。",
                  career: "网络工程师、网络安全工程师、运维工程师等"),
            Major(name: "物联网工程", category: "工学", duration: "四年制本科",
                  intro: "培养物联网系统设计、开发与应用方面的工程技术人才。",
                  career: "物联网工程师、嵌入式开发工程师等"),
            Major(name: "通信工程", category: "工学", duration: "四年制本科",
                  intro: "培养通信系统和通信网络的设计、开发、维护和管理方面的工程技术人才。",
                  career: "通信工程师、射频工程师、网络规划师等"),
            Major(name: "电子信息工程", category: "工学", duration: "四年制本科",
                  intro: "培养电子信息领域的系统设计、开发与应用方面的工程技术人才。",
                  career: "电子工程师、硬件工程师、信号处理工程师等"),
            Major(name: "智能科学与技术", category: "工学", duration: "四年制本科",
                  intro: "面向人工智能产业需求，培养智能算法、机器学习、深度学习等方向的专业人才。",
                  career: "AI工程师、算法工程师、数据科学家等"),
            Major(name: "电子信息科学与技术", category: "工学", duration: "四年制本科",
                  intro: "培养电子信息科学与技术领域的基础研究和应用开发人才。",
                  career: "研发工程师、技术支持工程师等"),
            Major(name: "虚拟现实技术", category: "工学", duration: "四年制本科",
                  intro: "培养VR/AR应用开发与设计人才，涵盖三维建模、交互设计、引擎开发等核心技术。",
                  career: "VR开发工程师、3D交互设计师、游戏开发者等"),
            Major(name: "电子与计算机工程", category: "工学", duration: "四年制本科",
                  intro: "融合电子工程与计算机科学的交叉学科，培养复合型工程技术人才。",
                  career: "嵌入式系统工程师、硬件开发工程师等"),
            Major(name: "数字媒体技术", category: "工学", duration: "四年制本科",
                  intro: "培养数字内容创作、多媒体技术开发与应用方面的专业人才。",
                  career: "多媒体开发工程师、UI/UX设计师等"),
            Major(name: "区块链工程", category: "工学", duration: "四年制本科",
                  intro: "新兴交叉学科，培养区块链系统设计与开发、智能合约编写的专业人才。",
                  career: "区块链工程师、智能合约开发、分布式系统工程师等"),
            Major(name: "计算机科学与技术（云计算方向）", category: "工学", duration: "四年制本科",
                  intro: "在计算机科学与技术基础上，增设云计算架构、虚拟化技术、容器化部署等特色课程。",
                  career: "云计算工程师、DevOps工程师、SRE工程师等"),
            Major(name: "计算机科学与技术（大数据方向）", category: "工学", duration: "四年制本科",
                  intro: "在计算机科学与技术基础上，增设大数据处理、数据挖掘、机器学习等特色课程。",
                  career: "大数据工程师、数据分析师、数据架构师等"),
        ]
    ),
    Department(
        name: "智能智造与车辆学院",
        englishName: "School of Intelligent Manufacturing & Vehicle",
        icon: "gearshape.2.fill",
        intro: "智能智造与车辆学院下设机械工程系、电气工程系两个系部，共开设9个本科专业。其中机械设计制造及其自动化为省级一流本科专业建设点，电气工程及其自动化为学校王牌专业。学院拥有87个实验室，包括3D打印实验室、智能硬件云实验室等先进设施。",
        siteKey: "znzzcl",
        subDepartments: ["机械工程系", "电气工程系"],
        majors: [
            Major(name: "机械设计制造及其自动化", category: "工学", duration: "四年制本科",
                  intro: "省级一流本科专业建设点，培养具备机械设计、制造、自动化控制等方面知识和技能的复合型工程技术人才。",
                  career: "机械工程师、制造工程师、设备工程师、质量工程师等"),
            Major(name: "过程装备与控制工程", category: "工学", duration: "四年制本科",
                  intro: "培养化工、石油、制药等行业过程装备设计、制造和控制方面的工程技术人才。",
                  career: "过程装备工程师、压力容器设计师等"),
            Major(name: "智能制造工程", category: "工学", duration: "四年制本科",
                  intro: "面向智能制造产业需求，培养智能装备设计、数字化工厂规划等方向的专业人才。",
                  career: "智能制造工程师、系统集成工程师、工业机器人工程师等"),
            Major(name: "车辆工程", category: "工学", duration: "四年制本科",
                  intro: "培养汽车设计、制造、试验及管理方面的工程技术人才。",
                  career: "汽车工程师、车辆测试工程师、底盘工程师等"),
            Major(name: "新能源汽车工程", category: "工学", duration: "四年制本科",
                  intro: "面向新能源汽车产业，培养电动汽车、混合动力汽车等设计开发方面的专业人才。",
                  career: "新能源汽车工程师、电池系统工程师等"),
            Major(name: "自动化", category: "工学", duration: "四年制本科",
                  intro: "培养自动控制系统设计、开发、运行和维护方面的工程技术人才。",
                  career: "自动化工程师、控制工程师、PLC工程师等"),
            Major(name: "电气工程及其自动化", category: "工学", duration: "四年制本科",
                  intro: "学校王牌专业，录取分数最高。培养电气系统设计、电力系统运行与控制方面的高级工程技术人才。",
                  career: "电气工程师、电力系统工程师、供配电工程师等"),
            Major(name: "测控技术与仪器", category: "工学", duration: "四年制本科",
                  intro: "培养精密测量、自动控制与仪器仪表方面的工程技术人才。",
                  career: "测控工程师、仪器仪表工程师、计量工程师等"),
            Major(name: "智能装备与系统", category: "工学", duration: "四年制本科",
                  intro: "培养智能装备系统设计、集成与运维方面的复合型工程技术人才。",
                  career: "智能装备工程师、系统集成工程师等"),
        ]
    ),
    Department(
        name: "商学院",
        englishName: "Business School",
        icon: "chart.bar.fill",
        intro: "商学院下设财会系、金融经济系、商务系三个系部，共开设11个本科专业，以经济学、管理学为主体，注重培养学生的商业思维和实践能力。学院与多家企业建立校企合作关系，为学生提供丰富的实习和就业机会。",
        siteKey: "sxy",
        subDepartments: ["财会系", "金融经济系", "商务系"],
        majors: [
            Major(name: "供应链管理", category: "管理学", duration: "四年制本科",
                  intro: "培养供应链规划、运营与管理方面的专业人才，涵盖采购、物流、仓储等全链条管理。",
                  career: "供应链经理、物流经理、采购经理等"),
            Major(name: "大数据管理与应用", category: "管理学", duration: "四年制本科",
                  intro: "融合大数据技术与管理学知识，培养数据驱动的商业决策人才。",
                  career: "数据分析师、商业分析师、数据产品经理等"),
            Major(name: "财务管理", category: "管理学", duration: "四年制本科",
                  intro: "培养具备财务分析、投融资决策、税务筹划等方面能力的财务管理人才。",
                  career: "财务经理、会计师、审计师、CFO等"),
            Major(name: "审计学", category: "管理学", duration: "四年制本科",
                  intro: "培养审计实务操作、内部控制与风险管理方面的专业人才。",
                  career: "审计师、内部审计、注册会计师等"),
            Major(name: "工商管理", category: "管理学", duration: "四年制本科",
                  intro: "培养企业管理、市场营销、人力资源等方面的综合管理人才。",
                  career: "企业管理、市场营销经理、人力资源经理等"),
            Major(name: "市场营销", category: "管理学", duration: "四年制本科",
                  intro: "培养市场调研、营销策划、品牌管理等方面的专业人才。",
                  career: "市场经理、品牌经理、营销策划师等"),
            Major(name: "跨境电子商务", category: "管理学", duration: "四年制本科",
                  intro: "面向跨境电商产业，培养国际贸易、平台运营、跨境物流等方面的复合型人才。",
                  career: "跨境电商运营、外贸专员、平台运营经理等"),
            Major(name: "经济学", category: "经济学", duration: "四年制本科",
                  intro: "培养具备经济分析和决策能力的高级专门人才。",
                  career: "经济分析师、金融从业者、政策研究员等"),
            Major(name: "国际经济与贸易", category: "经济学", duration: "四年制本科",
                  intro: "培养国际商务、国际贸易实务方面的专业人才。",
                  career: "外贸经理、国际贸易专员、报关员等"),
            Major(name: "互联网金融", category: "经济学", duration: "四年制本科",
                  intro: "培养互联网金融服务与管理人才，涵盖移动支付、网络信贷、数字货币等领域。",
                  career: "金融产品经理、风控分析师、数据分析师等"),
            Major(name: "金融工程", category: "经济学", duration: "四年制本科",
                  intro: "培养金融产品设计、风险管理与量化分析方面的专业人才。",
                  career: "金融工程师、量化分析师、风控经理等"),
        ]
    ),
    Department(
        name: "材料与环境学院",
        englishName: "School of Materials & Environment",
        icon: "leaf.fill",
        intro: "材料与环境学院下设材料工程系等系部，共开设6个本科专业，以材料科学与环境工程为特色，注重实践教学与科研结合。院长叶云教授是全国大学生材料分析大赛主任委员，学院拥有材料基础研究中心等校级科研平台。",
        siteKey: "clhj",
        subDepartments: ["材料工程系"],
        majors: [
            Major(name: "金属材料工程", category: "工学", duration: "四年制本科",
                  intro: "培养金属材料制备、加工、性能检测方面的工程技术人才。",
                  career: "材料工程师、质检工程师、研发工程师等"),
            Major(name: "材料成型及控制工程", category: "工学", duration: "四年制本科",
                  intro: "培养材料成型工艺设计与控制方面的工程技术人才。",
                  career: "材料工程师、工艺工程师、模具工程师等"),
            Major(name: "材料科学与工程", category: "工学", duration: "四年制本科",
                  intro: "培养材料科学研究与工程应用方面的复合型人才。",
                  career: "材料研发工程师、材料分析师等"),
            Major(name: "环境工程", category: "工学", duration: "四年制本科",
                  intro: "培养环境污染治理、环境监测与评价方面的专业人才，设有环境监测方向。",
                  career: "环保工程师、环境监测工程师、环评工程师等"),
            Major(name: "环境工程（环境监测方向）", category: "工学", duration: "四年制本科",
                  intro: "在环境工程基础上，增设环境监测技术、水质分析、大气监测等特色课程。",
                  career: "环境监测工程师、采样分析师、实验室技术员等"),
            Major(name: "安全工程", category: "工学", duration: "四年制本科",
                  intro: "培养安全生产管理、风险评估与控制方面的工程技术人才。",
                  career: "安全工程师、安全管理员、风险评估师等"),
        ]
    ),
    Department(
        name: "文法学院",
        englishName: "School of Humanities & Law",
        icon: "text.book.closed.fill",
        intro: "文法学院下设法学系等系部，共开设3个本科专业，以人文社科类专业为特色，注重培养学生的综合素质和人文素养。院长陈晋胜教授为知名法学专家。2025年5月与山西大学外国语学院签署共建合作协议，提升外语教学水平。",
        siteKey: "wfxy",
        subDepartments: ["法学系"],
        majors: [
            Major(name: "法学", category: "法学", duration: "四年制本科",
                  intro: "培养系统掌握法学知识，具备法律实务能力的专业人才。",
                  career: "律师、法官、检察官、企业法务等"),
            Major(name: "社会工作", category: "法学", duration: "四年制本科",
                  intro: "培养社会工作实务、社会服务管理方面的专业人才。",
                  career: "社会工作者、社工机构管理者、社区工作者等"),
            Major(name: "英语", category: "文学", duration: "四年制本科",
                  intro: "培养具备扎实英语语言基础和跨文化交际能力的应用型人才。",
                  career: "翻译、外贸专员、英语教师等"),
        ]
    ),
    Department(
        name: "艺术学院",
        englishName: "School of Art",
        icon: "music.note",
        intro: "艺术学院注重艺术与技术的融合，培养具有创新精神和实践能力的艺术人才。学院拥有专业音乐厅、舞蹈排练厅、模拟训练机舱等设施，与多家航空公司和艺术团体建立合作关系。",
        siteKey: "ysxy",
        majors: [
            Major(name: "航空服务艺术与管理", category: "艺术学", duration: "四年制本科",
                  intro: "培养航空服务管理与艺术素养兼备的复合型人才，学校拥有模拟训练机舱等专业设施。",
                  career: "航空乘务员、航空服务管理、礼仪培训师等"),
            Major(name: "音乐教育", category: "艺术学", duration: "四年制本科",
                  intro: "培养音乐表演与教学方面的专业人才。",
                  career: "音乐教师、演艺从业人员、音乐制作人等"),
        ]
    ),
    Department(
        name: "马克思主义学院",
        englishName: "School of Marxism",
        icon: "book.fill",
        intro: "马克思主义学院于2025年3月10日正式成立，承担全校思想政治理论课教学任务，是学校思想政治教育的主阵地。学院致力于推进马克思主义理论研究与思想政治教育创新。",
        siteKey: "mkszy",
        majors: []
    ),
    Department(
        name: "通识教育学院",
        englishName: "School of General Education",
        icon: "globe",
        intro: "通识教育学院负责全校通识教育课程的建设与管理，致力于提升学生综合素质，开设涵盖人文、科学、艺术等领域的通识课程。",
        siteKey: "tsxuey",
        majors: []
    ),
    Department(
        name: "国际交流与继续教育学院",
        englishName: "School of International Exchange & Continuing Education",
        icon: "airplane",
        intro: "国际交流与继续教育学院负责国际交流合作项目和继续教育管理。已与全球十余个国家和地区的百余所高校建立合作关系，包括麦考瑞大学、科廷大学、威斯康星大学、伦敦大学、新加坡国立大学等知名院校。",
        siteKey: "gjjljxjy",
        majors: []
    ),
    Department(
        name: "创新创业学院",
        englishName: "School of Innovation & Entrepreneurship",
        icon: "lightbulb.fill",
        intro: "创新创业学院负责全校创新创业教育，组织实施大学生创新训练计划，培养学生的创新精神和创业能力。学院定期举办创业大赛、创业讲座等活动，为有创业意向的学生提供指导和支持。",
        siteKey: "scxy",
        majors: []
    ),
    Department(
        name: "教务处",
        englishName: "Academic Affairs Office",
        icon: "pencil.and.list.clipboard",
        intro: "教务处是学校教学管理的核心职能部门，负责全校本科教学运行、学籍管理、考试管理、教学研究与改革、实践教学、教材建设、教学质量监控等工作。教务处秉承'服务教学、服务师生'的宗旨，致力于提高人才培养质量，推动教育教学改革创新。",
        siteKey: "jwc",
        subDepartments: ["教务科", "学籍科", "考试中心", "教学研究科", "实践教学科", "教材科", "质量监控科"],
        majors: []
    ),
]

// MARK: - 新闻

struct NewsItem: Identifiable, Codable {
    var id: String { title + date }
    let title: String
    let date: String
    let category: String
    let summary: String
    let content: String
    let imageUrl: String?
    let columnId: String?
    var articleId: String?
    let href: String?
    let author: String?
    let source: String?

    init(title: String, date: String, category: String, summary: String, content: String = "", imageUrl: String? = nil, columnId: String? = nil, articleId: String? = nil, href: String? = nil, author: String? = nil, source: String? = nil) {
        self.title = title; self.date = date; self.category = category
        self.summary = summary; self.content = content.isEmpty ? summary : content
        self.imageUrl = imageUrl; self.columnId = columnId; self.articleId = articleId
        self.href = href; self.author = author; self.source = source
    }

    /// 已读状态唯一键：优先使用 articleId，回退到 title+date
    var readKey: String { articleId ?? id }

    /// 智能构造原文链接，按优先级：
    /// 1. href 为有效绝对 URL（http/https 开头）→ 直接使用
    /// 2. href 为非平凡相对路径（非 "/"、非空）→ 拼接学校域名
    /// 3. 有 articleId → 构造学校官网文章详情页 URL
    /// 4. 兜底 → 学校首页
    var originalArticleURL: String {
        // 1. 有效的绝对 URL
        if let href = href, !href.isEmpty, href != "/",
           let url = URL(string: href),
           url.scheme == "http" || url.scheme == "https" {
            return href
        }
        // 2. 非平凡相对路径（如 /news/xxx、/articles/xxx）
        if let href = href, !href.isEmpty, href != "/", href.hasPrefix("/") {
            return SchoolInfo.website + href
        }
        // 3. 基于 articleId 构造学校官网 SPA 文章详情页
        if let articleId = articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        // 4. 兜底：学校首页
        return SchoolInfo.website
    }
}

let defaultNews: [NewsItem] = [
    NewsItem(title: "暑期聚力攻坚 实干赋能发展——我校各部门凝心实干筑牢校园发展根基",
             date: "2026.08.01", category: "新闻资讯",
             summary: "为全面夯实校园办学根基、优化育人环境，以全新面貌迎接新学期，我校各部门围绕校园基建翻新、基础设施建设等重点工作全线发力。",
             content: "为全面夯实校园办学根基、优化育人环境、提升服务保障水平，以全新面貌迎接新学期、新学子，我校坚持领导班子带班值守、统筹调度，各职能部门围绕校园基建翻新、基础设施建设、行政效能提升、实践育人赋能、舆情实时监测、学生成长护航等重点工作全线发力、真抓实干。全校上下凝心聚力、协同联动，以实干担当为学校高质量长远发展蓄势赋能。",
             author: "党委宣传部", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校艺术学院学子在2026交通运输产教融合系列活动中荣获佳绩",
             date: "2026.07.30", category: "学校要闻",
             summary: "7月17日至30日，以'智能·协同·融合：助力教育强国'为主题的2026交通运输产教融系列活动在广慧金通国际航空培训中心举办。",
             content: "7月17日至30日，以'智能·协同·融合：助力教育强国'为主题的2026交通运输产教融合系列活动在广慧金通国际航空培训中心举办。我校艺术学院学子在活动中表现优异，充分展现了学校产教融合育人的丰硕成果。",
             author: "艺术学院", source: "山西晋中理工学院官网"),
    NewsItem(title: "情系边疆学子 暖心奔赴一线 我校教师赴新疆看望西部计划志愿者",
             date: "2026.07.30", category: "新闻资讯",
             summary: "我校团委书记于乐等教师代表远赴新疆各地，开展西部计划志愿者走访慰问活动。",
             content: "近日，我校团委书记于乐等教师代表远赴新疆各地，开展西部计划志愿者走访慰问活动，实地看望坚守边疆服务一线的我校青年学子，以暖心奔赴践行育人初心，以真情关怀护航青年成长。",
             author: "校团委", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校召开干部教师会议 宣布党委主要领导调整决定",
             date: "2026.07.14", category: "学校要闻",
             summary: "7月13日，我校召开干部教师会议，宣布省委、省委教育工委关于学校党委主要领导调整的决定。",
             content: "7月13日，我校召开干部教师会议，宣布省委、省委教育工委关于学校党委主要领导调整的决定。会议强调，要加强党对学校工作的全面领导，落实立德树人根本任务，推动学校高质量发展再上新台阶。",
             author: "党委组织部", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校召开合格评估与高质量发展大会",
             date: "2026.06.30", category: "学校要闻",
             summary: "学校召开合格评估与高质量发展大会，全面部署迎评促建工作。",
             content: "为全面深化课程改革，进一步推动人工智能赋能教学，凝聚全校育人共识，顺利通过本科教学工作合格评估，提升办学治校质量，6月26日至28日，我校在长治市青松岭召开合格评估与高质量发展大会。",
             author: "教务处", source: "山西晋中理工学院官网"),
    NewsItem(title: "山西晋中理工学院2026年招聘简章",
             date: "2026.06.04", category: "通知公告",
             summary: "山西晋中理工学院2026年招聘简章",
             content: "为了进一步加强我校师资队伍建设，深入实施人才强校战略，深化产学研用合作，提高专业建设水平，山西晋中理工学院现面向社会引进各类人才。",
             author: "人事处", source: "山西晋中理工学院官网"),
    NewsItem(title: "山西晋中理工学院2026年招生章程发布",
             date: "2026.05.20", category: "招生信息",
             summary: "山西晋中理工学院2026年本科招生章程正式发布，涵盖44个本科专业招生计划。",
             content: "根据教育部和山西省教育厅关于做好2026年普通高校招生工作的通知要求，我校制定并发布2026年本科招生章程。学校面向全国多个省份招生，涵盖工学、经济学、管理学、法学、文学、艺术学等学科门类，共计44个本科专业。",
             author: "招生就业处", source: "山西晋中理工学院招生网"),
    NewsItem(title: "信创与大数据学院举办第二届'智创未来'科技创新大赛",
             date: "2026.05.15", category: "院部动态",
             summary: "信创与大数据学院第二届'智创未来'科技创新大赛圆满落幕，近百支学生团队参赛。",
             content: "5月12日至15日，信创与大数据学院主办的'智创未来'科技创新大赛在学院实验中心举行。本次大赛共吸引来自全校各专业的98支团队参赛，作品涵盖人工智能、区块链、虚拟现实、物联网等前沿技术领域，充分展现了学生的创新能力和实践水平。",
             author: "信创与大数据学院", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校与晋中经济技术开发区签署产学研合作协议",
             date: "2026.04.28", category: "学校要闻",
             summary: "学校与晋中经济技术开发区签署战略合作协议，共建产学研合作基地。",
             content: "4月26日，山西晋中理工学院与晋中经济技术开发区签署产学研战略合作协议。双方将在人才培养、技术支持、科研成果转化等方面开展深度合作，共建产学研合作基地，为区域经济发展提供人才支撑和智力支持。",
             author: "科技处", source: "山西晋中理工学院官网"),
    NewsItem(title: "关于2026年五一劳动节放假安排的通知",
             date: "2026.04.25", category: "通知公告",
             summary: "学校发布2026年五一劳动节放假安排，5月1日至5日放假调休共5天。",
             content: "根据国家法定节假日安排，结合学校实际，2026年五一劳动节放假安排如下：5月1日（周五）至5月5日（周二）放假调休，共5天。4月26日（周日）补5月4日（周一）的课程，5月9日（周六）补5月5日（周二）的课程。",
             author: "学校办公室", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校举办2026届毕业生春季校园双选会",
             date: "2026.03.20", category: "招生就业",
             summary: "2026届毕业生春季校园双选会成功举办，200余家用人单位提供就业岗位5000余个。",
             content: "3月18日至19日，山西晋中理工学院2026届毕业生春季校园双选会在学校体育馆举行。本次双选会共邀请省内外200余家用人单位参会，提供就业岗位5000余个，涵盖机械制造、信息技术、金融服务、教育培训等多个行业领域。",
             author: "招生就业处", source: "山西晋中理工学院官网"),
    NewsItem(title: "我校教师在山西省高校青年教师教学竞赛中获佳绩",
             date: "2026.03.10", category: "学校要闻",
             summary: "我校教师在2026年山西省高校青年教师教学竞赛中荣获一等奖1项、二等奖2项。",
             content: "在刚刚结束的2026年山西省高校青年教师教学竞赛中，我校信创与大数据学院张老师荣获工科组一等奖，商学院李老师荣获文科组二等奖，材料与环境学院王老师荣获理科组二等奖，充分展示了我校青年教师的教学风采和专业水平。",
             author: "教务处", source: "山西晋中理工学院官网"),
]

// MARK: - 学生故事

struct StudentStory: Identifiable, Codable {
    var id: String { articleId ?? title }
    let title: String
    let summary: String
    let imageUrl: String?
    let date: String?
    var articleId: String? = nil
}

let defaultStudentStories: [StudentStory] = [
    StudentStory(title: "从晋理到北航——学霸的考研之路",
                 summary: "信创与大数据学院2025届毕业生李明，以优异成绩考取北京航空航天大学计算机科学与技术专业硕士研究生。大学四年，专业成绩排名第一，获国家奖学金2次，发表SCI论文1篇。",
                 imageUrl: nil,
                 date: "2025.06"),
    StudentStory(title: "西部计划志愿者——用青春书写边疆情怀",
                 summary: "商学院2024届毕业生王芳，毕业后主动报名参加大学生志愿服务西部计划，扎根新疆阿克苏地区，用专业知识和青春热情服务边疆建设，获评'优秀志愿者'称号。",
                 imageUrl: nil,
                 date: "2025.05"),
    StudentStory(title: "创业之星——从校园团队到百万营收",
                 summary: "智能智造与车辆学院2023届毕业生张伟，在校期间创立科技公司，专注于智能硬件研发。团队从3人起步，目前公司年营收突破500万元，带动就业20余人。",
                 imageUrl: nil,
                 date: "2025.04"),
    StudentStory(title: "设计新锐——全国大学生广告艺术大赛一等奖",
                 summary: "艺术学院2022级视觉传达设计专业学生陈思雨，凭借作品《晋韵悠长》荣获2025年全国大学生广告艺术大赛一等奖，作品被多家媒体转载报道。",
                 imageUrl: nil,
                 date: "2025.08"),
    StudentStory(title: "运动健儿——山西省大学生田径锦标赛三金得主",
                 summary: "文法学院2023级学生赵强，在2025年山西省大学生田径锦标赛中斩获男子100米、200米和4×100米接力三枚金牌，打破学校纪录，展现晋理学子拼搏精神。",
                 imageUrl: nil,
                 date: "2025.07"),
]

// MARK: - 教师风采

struct TeacherProfile: Identifiable, Codable {
    var id: String { articleId ?? title }
    let title: String
    let summary: String
    let imageUrl: String?
    let date: String?
    var articleId: String? = nil
}

let defaultTeacherProfiles: [TeacherProfile] = [
    TeacherProfile(title: "张教授——电子与计算机工程学科带头人",
                   summary: "信创与大数据学院院长，博士生导师，山西省教学名师。主持国家级科研项目3项，发表SCI/EI论文50余篇，获省部级科技进步奖2项。",
                   imageUrl: nil,
                   date: "2025.09"),
    TeacherProfile(title: "李老师——全国高校青年教师教学竞赛一等奖",
                   summary: "商学院副教授，经济学博士。2025年荣获全国高校青年教师教学竞赛文科组一等奖，教学风格深受学生喜爱，被评为'最受欢迎教师'。",
                   imageUrl: nil,
                   date: "2025.08"),
    TeacherProfile(title: "王教授——智能制造领域专家",
                   summary: "智能智造与车辆学院教授，山西省「三晋英才」支持计划入选者。长期从事智能制造、数字化工厂方向研究，与企业合作开发多项智能装备。",
                   imageUrl: nil,
                   date: "2025.06"),
    TeacherProfile(title: "赵老师——优秀辅导员标兵",
                   summary: "材料与环境学院辅导员，从事学生工作10年。获评2025年山西省高校优秀辅导员标兵，所带班级多次获评省级先进班集体。",
                   imageUrl: nil,
                   date: "2025.05"),
    TeacherProfile(title: "刘教授——法学教育耕耘者",
                   summary: "文法学院教授，中国法学会会员。长期从事民商法学教学与研究，出版专著3部，主持省级教学改革项目5项，培养了大批优秀法律人才。",
                   imageUrl: nil,
                   date: "2025.04"),
]

// MARK: - 校园视频

struct CampusVideo: Identifiable, Codable {
    var id: String { title + videoUrl }
    let title: String
    let videoUrl: String
    let thumbnailUrl: String?
    let description: String?
}

let defaultVideos: [CampusVideo] = [
    CampusVideo(title: "山西晋中理工学院宣传片",
                videoUrl: "https://www.sxjzit.edu.cn/video/promotional.mp4",
                thumbnailUrl: "https://www.sxjzit.edu.cn/video/thumb1.jpg",
                description: "全面展示山西晋中理工学院的校园风貌、办学特色和育人成果"),
    CampusVideo(title: "2025级新生军训汇报表演",
                videoUrl: "https://www.sxjzit.edu.cn/video/military2025.mp4",
                thumbnailUrl: "https://www.sxjzit.edu.cn/video/thumb2.jpg",
                description: "2025级新生军训汇报表演精彩瞬间，展现晋理学子的昂扬斗志"),
    CampusVideo(title: "校园文化艺术节开幕式",
                videoUrl: "https://www.sxjzit.edu.cn/video/artfestival.mp4",
                thumbnailUrl: "https://www.sxjzit.edu.cn/video/thumb3.jpg",
                description: "第十五届校园文化艺术节开幕式文艺演出精彩回顾"),
    CampusVideo(title: "毕业季·不说再见",
                videoUrl: "https://www.sxjzit.edu.cn/video/graduation2025.mp4",
                thumbnailUrl: "https://www.sxjzit.edu.cn/video/thumb4.jpg",
                description: "2025届毕业生毕业典礼暨学位授予仪式温情回顾"),
    CampusVideo(title: "我在晋理的一天",
                videoUrl: "https://www.sxjzit.edu.cn/video/campuslife.mp4",
                thumbnailUrl: "https://www.sxjzit.edu.cn/video/thumb5.jpg",
                description: "跟随镜头体验山西晋中理工学院学生丰富多彩的校园生活"),
]

// MARK: - 校园活动

struct CampusActivity: Identifiable, Codable {
    var id: String { articleId ?? title }
    let title: String
    let summary: String
    let imageUrl: String?
    let date: String?
    let englishTitle: String?
    var articleId: String? = nil
}

let defaultCampusActivities: [CampusActivity] = [
    CampusActivity(title: "第十五届校园文化艺术节",
                   summary: "以'青春筑梦·强国有我'为主题的校园文化艺术节，涵盖歌手大赛、舞蹈大赛、书画展览、话剧专场等十余项活动，历时一个月，参与学生超过5000人次。",
                   imageUrl: nil,
                   date: "2025.11", englishTitle: "The 15th Campus Culture & Art Festival"),
    CampusActivity(title: "2025年秋季运动会",
                   summary: "全校师生共同参与的体育盛会，设有田径、球类、趣味运动等30余个比赛项目，8人次打破学校纪录，展现了晋理人顽强拼搏的体育精神。",
                   imageUrl: nil,
                   date: "2025.10", englishTitle: "2025 Autumn Sports Meeting"),
    CampusActivity(title: "科技创新月系列活动",
                   summary: "由教务处、科技处联合主办，包含科技创新成果展、学术讲座、实验室开放日、创新创业大赛等系列活动，激发学生科技创新热情。",
                   imageUrl: nil,
                   date: "2025.12", englishTitle: "Science & Technology Innovation Month"),
    CampusActivity(title: "迎新晚会——'梦想起航'",
                   summary: "为2025级新生精心打造的迎新文艺晚会，融合歌舞、器乐、朗诵、魔术等多种艺术形式，展现学校文化底蕴和青春活力，现场观众超过3000人。",
                   imageUrl: nil,
                   date: "2025.09", englishTitle: "Welcome Gala - Dreams Set Sail"),
    CampusActivity(title: "'五四'青年节主题教育活动",
                   summary: "纪念五四运动106周年系列活动，包括主题团日、青年榜样事迹分享会、志愿服务进社区、红色教育基地参观学习等。",
                   imageUrl: nil,
                   date: "2025.05", englishTitle: "May Fourth Youth Day Themed Activities"),
    CampusActivity(title: "校园十佳歌手大赛",
                   summary: "一年一度的校园歌手大赛，经过海选、复赛、决赛层层选拔，最终评选出年度校园十佳歌手，成为校园文化品牌活动之一。",
                   imageUrl: nil,
                   date: "2025.11", englishTitle: "Campus Top 10 Singers Competition"),
]

// MARK: - 校园风光

struct CampusScenery: Identifiable, Codable {
    var id: String { title }
    let title: String
    let imageUrl: String?
    let description: String?
}

let defaultCampusSceneries: [CampusScenery] = [
    CampusScenery(title: "学校正门",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/gate.jpg",
                  description: "山西晋中理工学院的主校门，庄重大气，彰显现代大学风采，是每位学子梦想起航的地方。"),
    CampusScenery(title: "图书馆",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/library.jpg",
                  description: "建筑面积2.4万平方米的现代化图书馆，藏书120余万册，是知识的海洋、学习的殿堂。"),
    CampusScenery(title: "教学楼群",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/teaching.jpg",
                  description: "现代化的教学楼群，配备先进的多媒体教学设备，为师生提供优质的教学环境。"),
    CampusScenery(title: "田径运动场",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/stadium.jpg",
                  description: "标准400米塑胶跑道田径场，绿草如茵的足球场，是师生运动健身、挥洒汗水的好去处。"),
    CampusScenery(title: "校园湖畔",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/lake.jpg",
                  description: "校园中心的人工湖，碧波荡漾，垂柳依依，是晨读、散步、放松身心的绝佳场所。"),
    CampusScenery(title: "实验实训中心",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/lab.jpg",
                  description: "拥有87个专业实验室的现代化实验实训中心，为学生提供充足的实践教学条件。"),
    CampusScenery(title: "学生公寓区",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/dormitory.jpg",
                  description: "省级发改委批复定价的学生公寓区：14 栋已建成 + 2 栋新建，四档收费、独立阳台、网络全覆盖。"),
    CampusScenery(title: "秋日校园",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/autumn.jpg",
                  description: "金秋时节的校园，银杏叶黄，枫叶正红，层林尽染，美不胜收。"),
    CampusScenery(title: "校园夜景",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/night.jpg",
                  description: "夜幕降临，华灯初上，校园在璀璨灯光的映衬下更显宁静与美丽。"),
    CampusScenery(title: "大学生活动中心",
                  imageUrl: "https://www.sxjzit.edu.cn/scenery/activity.jpg",
                  description: "集社团活动、文艺演出、学术交流于一体的大学生活动中心，是校园文化的重要阵地。"),
]

// MARK: - 校园服务

struct CampusService: Identifiable, Codable {
    var id: String { name }
    let name: String
    let icon: String
    let url: String
}

let defaultServices: [CampusService] = [
    CampusService(name: "教务系统", icon: "graduationcap.fill", url: "http://jwglxt.sxjzit.edu.cn/jwglxt/xtgl/login_slogin.html"),
    CampusService(name: "图书馆", icon: "books.vertical.fill", url: "https://www.sxjzit.edu.cn/#/departments/page?site_key=tsg"),
    CampusService(name: "招生网", icon: "person.crop.circle.badge.plus", url: "https://www.sxjzit.edu.cn/#/departments/page?site_key=zsw"),
    CampusService(name: "就业信息", icon: "briefcase.fill", url: "https://jygl.sxjzit.edu.cn/"),
    CampusService(name: "校长信箱", icon: "text.bubble.fill", url: "https://www.sxjzit.edu.cn/#/opinion"),
    CampusService(name: "国际交流", icon: "globe.asia.australia.fill", url: "https://www.sxjzit.edu.cn/#/collaboration"),
    CampusService(name: "校园日历", icon: "calendar", url: "sxjzit://campus-calendar"),
]

// MARK: - 校园设施

/// 设施分区键值对（指标/规则类信息的「标签—数值」行）
struct FacilityInfoPair: Identifiable, Codable, Hashable {
    var id: String { label }
    let label: String
    let value: String
}

/// 设施分区（复杂设施如食堂、图书馆的分块信息；普通设施不提供，详情页自动回退经典样式）
struct FacilitySection: Identifiable, Codable, Hashable {
    var id: String { title }
    let title: String
    var subtitle: String? = nil
    let desc: String
    let highlights: [String]
    /// 键值指标行（可选）：规则、数据类信息以「标签—数值」成对展示
    var infoPairs: [FacilityInfoPair]? = nil
    /// 分区主题色（十六进制，如 "3A9D5C"；缺省时按内置调色板序取色）
    var accentHex: String? = nil

    init(title: String, subtitle: String? = nil, desc: String, highlights: [String],
         accentHex: String? = nil, infoPairs: [FacilityInfoPair]? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.desc = desc
        self.highlights = highlights
        self.accentHex = accentHex
        self.infoPairs = infoPairs
    }

    enum CodingKeys: String, CodingKey { case title, subtitle, desc, highlights, accentHex, infoPairs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        desc = try container.decode(String.self, forKey: .desc)
        highlights = try container.decode([String].self, forKey: .highlights)
        accentHex = try container.decodeIfPresent(String.self, forKey: .accentHex)
        infoPairs = try container.decodeIfPresent([FacilityInfoPair].self, forKey: .infoPairs)
    }
}

struct Facility: Identifiable, Codable {
    var id: String { name }
    let name: String
    let icon: String
    let desc: String
    let details: [String]
    /// 可选分区信息：有值时详情页按分区卡片展示；nil 时使用经典「简介 + 详细信息」样式
    var sections: [FacilitySection]? = nil

    init(name: String, icon: String, desc: String, details: [String], sections: [FacilitySection]? = nil) {
        self.name = name; self.icon = icon; self.desc = desc; self.details = details; self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case name, icon, desc, details, sections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        desc = try container.decode(String.self, forKey: .desc)
        details = try container.decode([String].self, forKey: .details)
        // sections 为新增可选字段：旧数据/外部数据无此键时容错为 nil（自动回退经典样式）
        sections = try container.decodeIfPresent([FacilitySection].self, forKey: .sections)
    }
}

let defaultFacilities: [Facility] = [
    Facility(name: "图书馆", icon: "building.columns.fill",
             desc: "馆舍地上五层、地下一层，总面积 1.7 万平方米，可同时容纳 2600 余名师生学习。截至 2024 年 12 月 31 日，馆藏图书 127.83 万册、15.9 万余种，电子图书 139.93 万种，紧邻高铁晋中站。",
             details: [],
             sections: [
                FacilitySection(
                    title: "历史沿革",
                    subtitle: "肇始于 2002",
                    desc: "图书馆随学校发展历经旧馆期与新馆期：2002 年随院校建立逐步筹建，2013 年旧馆正式开馆，2019 年前后迁入新馆并进入试运行，2021 年随学校转设为山西晋中理工学院后持续扩充馆藏、升级服务。",
                    highlights: [
                        "2002 年：随院校建立，图书馆逐步筹建",
                        "2013 年：旧馆正式开馆",
                        "2019 年前后：迁入新馆试运行",
                        "2021 年至今：转设后馆藏扩充、服务升级",
                    ],
                    accentHex: "2A6FDB"),
                FacilitySection(
                    title: "建筑概况",
                    subtitle: "地上五层 · 地下一层 · 1.7 万㎡",
                    desc: "馆舍地上五层、地下一层，总面积 1.7 万平方米（学校官网口径）。馆内功能分区科学合理，设施配备完善先进，可同时容纳 2600 余名师生开展学习、备课及学术交流活动。",
                    highlights: [],
                    accentHex: "3A9D5C",
                    infoPairs: [
                        FacilityInfoPair(label: "总建筑面积", value: "1.7 万平方米"),
                        FacilityInfoPair(label: "楼层结构", value: "地上 5 层 · 地下 1 层"),
                        FacilityInfoPair(label: "自习容量", value: "可同时容纳 2600 余名师生"),
                        FacilityInfoPair(label: "新馆启用", value: "2019 年前后试运行/启用"),
                    ]),
                FacilitySection(
                    title: "馆藏资源",
                    subtitle: "截至 2024 年 12 月 31 日（官网口径）",
                    desc: "图书馆文献资源总量稳步增长。截至 2024 年 12 月 31 日，馆藏图书 127.83 万册、15.9 万余种，当年新增纸本图书 6.7 万余册，生均纸质图书 76.1 册。藏书涵盖政治、哲学、经济、社会科学、自然科学、教育、文学、艺术等，在工业技术、自然科学、经济、艺术领域重点收藏，理工类图书占比超藏书总量的 50%。",
                    highlights: [
                        "理工类图书占比超藏书总量的 50%",
                        "工业技术 · 自然科学 · 经济 · 艺术重点收藏",
                    ],
                    accentHex: "C8A24B",
                    infoPairs: [
                        FacilityInfoPair(label: "纸质图书", value: "127.83 万册 · 15.9 万余种"),
                        FacilityInfoPair(label: "当年新增", value: "纸本图书 6.7 万余册"),
                        FacilityInfoPair(label: "生均纸质图书", value: "76.1 册"),
                        FacilityInfoPair(label: "报刊 · 期刊", value: "16 种 · 57 种"),
                        FacilityInfoPair(label: "硕士学位论文", value: "35.322 万册"),
                    ]),
                FacilitySection(
                    title: "数字资源",
                    subtitle: "知网 + 超星汇雅（官网确认）",
                    desc: "拥有电子图书 139.93 万种，其中固定电子图书资源 9 万册、电子期刊 5968 册。数字图书馆包括中国知网 CNKI 数据库与超星汇雅电子图书数据库，全年电子资源访问量 7,814,094 次、下载量 153,999 次。",
                    highlights: [
                        "电子图书 139.93 万种 · 电子期刊 5968 册",
                        "全年访问量 781 万余次 · 下载 15.4 万次",
                    ],
                    accentHex: "4C6EF5",
                    infoPairs: [
                        FacilityInfoPair(label: "学术数据库", value: "中国知网 CNKI"),
                        FacilityInfoPair(label: "电子图书库", value: "超星汇雅"),
                    ]),
                FacilitySection(
                    title: "馆内空间",
                    subtitle: "分区科学合理 · 设施完善先进",
                    desc: "馆内设有书库、密集书库、馆藏室、自习室、教师阅览室、会议室、期刊阅览室、报刊阅览室、报告厅等多个功能区域，满足借阅、自习、备课与学术交流等多样化需求。",
                    highlights: [
                        "书库 · 密集书库 · 馆藏室 · 自习室",
                        "教师阅览室 · 期刊阅览室 · 报刊阅览室",
                        "会议室 · 报告厅（学术交流活动）",
                    ],
                    accentHex: "0E9AA7"),
                FacilitySection(
                    title: "开放时间",
                    subtitle: "周一至周日 7:15—22:00",
                    desc: "图书馆正常开馆时间为周一至周日：上午 7:15—12:00，下午 12:00—22:00。国庆、中秋、端午等节假日按当次调整通知执行，请以馆内公告与公众号通知为准。",
                    highlights: [],
                    accentHex: "E07B39",
                    infoPairs: [
                        FacilityInfoPair(label: "运营开放", value: "周一至周日"),
                        FacilityInfoPair(label: "上午", value: "7:15—12:00"),
                        FacilityInfoPair(label: "下午", value: "12:00—22:00"),
                        FacilityInfoPair(label: "节假日", value: "以当次调整通知为准"),
                    ]),
                FacilitySection(
                    title: "借阅服务",
                    subtitle: "官网《图书借阅须知》口径",
                    desc: "读者凭本人学生证借阅。学生每人最多可借 5 本、借期 30 天；教师每人最多可借 10 本、借期 90 天。每本书仅可续借一次、续借 30 天（自续借当日起算），在一层总服务台办理。图书逾期未还将暂停借阅权限，并按每册每日 0.20 元收取滞纳金；期刊、报刊仅限馆内阅览，不可外借。",
                    highlights: [
                        "微信小程序预约借书 → 生成借阅二维码 → 扫码借阅",
                        "污损图书每页赔偿 1-5 元；遗失或严重损坏按原价 5 倍赔偿，另加 5 元加工费",
                        "寒、暑假及毕业离校前须还清全部图书",
                    ],
                    accentHex: "8E5BC9",
                    infoPairs: [
                        FacilityInfoPair(label: "学生借阅", value: "最多 5 本 · 借期 30 天"),
                        FacilityInfoPair(label: "教师借阅", value: "最多 10 本 · 借期 90 天"),
                        FacilityInfoPair(label: "续借", value: "每书 1 次 · 30 天（总服务台）"),
                        FacilityInfoPair(label: "逾期处理", value: "暂停借阅 · 0.20 元/册/日"),
                    ]),
                FacilitySection(
                    title: "考研专区",
                    subtitle: "固定座位 · 预约管理 · 动态回收",
                    desc: "2026 年考研空间显著扩容，覆盖多楼区：三楼 188 座、六区负一楼 180 座、六楼 200 座、西楼四层北 137 座（配 640 个资料存放格），B 座 5 层暑期改造后开放线上预约。专区面向本校当年备考硕士研究生的在校学生，专人管理、定时巡查，低利用率座位动态回收；人走桌净、食品不留过夜，严禁存放充电宝、暖手宝等消防风险物品。",
                    highlights: [
                        "西楼四层北：137 座 + 640 个考研资料存放格",
                        "B 座 5 层：2026 暑期设施全面更新升级",
                        "线上预约 · 部分区域线下审核选座",
                        "离座超 1 小时未取物视为违规占座",
                    ],
                    accentHex: "C8102E"),
                FacilitySection(
                    title: "服务与活动",
                    subtitle: "借阅 · 自习 · 电子资源 · 活动讲座",
                    desc: "图书馆提供图书借阅、自习、电子资源与参考咨询等服务，定期举办读书分享会、讲座、展览等文化活动。读者可在图书馆微信小程序中在线预约借书，生成借阅二维码后由馆员扫码办理。如有疑问可拨打图书馆值班电话。",
                    highlights: [
                        "微信小程序预约借书 · 扫码借阅",
                        "读书分享会 · 讲座 · 展览等文化活动",
                        "2026 级新生入馆教育：1 万余名新生参与",
                    ],
                    accentHex: "2B7A5F",
                    infoPairs: [
                        FacilityInfoPair(label: "图书馆值班电话", value: "0354-2459184"),
                    ]),
                FacilitySection(
                    title: "入馆须知",
                    subtitle: "文明阅读 · 共同维护",
                    desc: "读者凭本人学生证或身份证入馆。图书馆为重点防火单位，严禁携带易燃、易爆、有毒等危险品入馆，严禁吸烟和使用明火，严禁使用大功率电器；馆内期刊、报刊仅限室内阅览；已借图书请勿带入馆内；阅览区域请将手机调至静音，禁止抢占座位。",
                    highlights: [
                        "凭本人学生证或身份证入馆",
                        "严禁易燃易爆品 · 吸烟明火 · 大功率电器",
                        "期刊报刊仅限馆内阅览 · 已借图书勿带入馆",
                        "文明阅读：手机静音 · 禁止占座",
                    ],
                    accentHex: "6B7280"),
             ]),
    Facility(name: "实验实训中心", icon: "flask.fill",
             desc: "「校级中心 + 新建实训楼群 + 学院级实验中心 + 校外基地」四位一体的实验实训体系：实验室 87 个（2026 年官网口径）、教学科研仪器设备总值超 1.5 亿元、校外实习基地 105 个，17#—20# 实训楼为 2023 年晋中市市级重点工程。",
             details: [],
             sections: [
                FacilitySection(
                    title: "体系总览",
                    subtitle: "四位一体 · 87 个实验室",
                    desc: "学校实验实训体系由「校级中心 + 新建实训楼群 + 学院级实验中心 + 校外基地」构成。建有实验室 87 个（2026 年官网口径；2021 年转设时为 73 个），涵盖计算机、电工、电子、自动化、机械实训中心、车辆实训、金工实习等领域。教学科研仪器设备总值自 2021 年 7000 余万元跃升至 2026 年超 1.5 亿元。",
                    highlights: [
                        "标志性实验室：3D 打印 · 智能硬件云 · 模拟训练机舱 · 企业全景运营 AR 实训室",
                        "校外实习基地覆盖北京、上海、广东、江苏、浙江、福建、湖北等省市",
                    ],
                    accentHex: "2A6FDB",
                    infoPairs: [
                        FacilityInfoPair(label: "实验室总数", value: "87 个（2026 官网口径）"),
                        FacilityInfoPair(label: "设备总值", value: "超 1.5 亿元（2026 官方视频）"),
                        FacilityInfoPair(label: "校外实习基地", value: "105 个"),
                    ]),
                FacilitySection(
                    title: "工程实训中心",
                    subtitle: "校级综合实践平台 · 九大方向",
                    desc: "学校校级综合性实践教学平台，被官方描述为「科技与创新的实践殿堂」，以真实工业环境为蓝本、以工科为引领。中心内多学科交织，覆盖智能制造、3D 特种加工、新能源汽车开发与应用、材料分析、VR、大数据、电子工艺、云财务、经济与金融九大方向。",
                    highlights: [
                        "九大方向：智能制造 · 3D特种加工 · 新能源汽车 · 材料分析",
                        "VR · 大数据 · 电子工艺 · 云财务 · 经济与金融",
                        "「工训203」电子创新实验室：32/52 单片机 · EDA · 3D 建模（2022 纳新 110 人进群、录取约 30 人）",
                        "重要接待：2024 山西省侨联调研 · 2025 市校党建共建参观考察",
                    ],
                    accentHex: "3A9D5C"),
                FacilitySection(
                    title: "17#—20# 实训楼",
                    subtitle: "3.6 万㎡ · 2023 市级重点工程",
                    desc: "学校近年最大规模的实训基建——17#、18#、19#、20# 实训楼项目总建设规模 36284.78㎡，2023 年 4 月 3 日取得建设工程规划许可证（建字第140700202300011号），列入 2023 年晋中市市级重点工程项目（科教人才类第 46 项）。20# 实训楼于 2023 年 6 月 15 日主体结构提前封顶，此后进入装饰装修及设备安装阶段。",
                    highlights: [
                        "20# 实训楼 2023-06-15 主体提前封顶",
                    ],
                    accentHex: "E07B39",
                    infoPairs: [
                        FacilityInfoPair(label: "总建设规模", value: "36284.78㎡（四栋合计）"),
                        FacilityInfoPair(label: "规划许可证号", value: "建字第140700202300011号"),
                        FacilityInfoPair(label: "项目地位", value: "2023 晋中市市级重点工程"),
                    ]),
                FacilitySection(
                    title: "20# 实训楼",
                    subtitle: "六层剪力墙 · 消能减震 · 容纳 1225 人",
                    desc: "位于校园西北侧：占地 1440.95㎡、总建筑面积 8976.58㎡，地上六层（多层公共建筑），建筑高度 19.70 米，剪力墙结构、筏板基础，采用消能减震技术，设计容纳 1225 人，定位为大学生技能训练和考核场所。一至六层设实训室、教研办公室、公共活动室等。施工单位为建安公司（中铁三局建安公司第二工程队承建；另有中铁建工集团一说，以施工铭牌为准），监理为晋中市正元建设监理有限公司。",
                    highlights: [],
                    accentHex: "4C6EF5",
                    infoPairs: [
                        FacilityInfoPair(label: "占地面积", value: "1440.95㎡"),
                        FacilityInfoPair(label: "总建筑面积", value: "8976.58㎡"),
                        FacilityInfoPair(label: "层数 · 高度", value: "地上六层 · 19.70 米"),
                        FacilityInfoPair(label: "结构形式", value: "剪力墙 + 筏板基础 + 消能减震"),
                        FacilityInfoPair(label: "设计容量", value: "1225 人"),
                    ]),
                FacilitySection(
                    title: "学院中心 · 工科",
                    subtitle: "智能制造与车辆 · 材料与环境",
                    desc: "智能制造与车辆学院拥有约 2000㎡ 实验室与 1300 余万元设备、20 多个高水平实验室（机械 VR 实训中心、发动机检测中心、自动控制综合实验室、电气实验室），覆盖滚动轴承应力分析、液压传动与控制、发动机性能、运动控制等机械/车辆/电气/自动化专业群。材料与环境学院设校级材料基础研究中心，是首个承办山西省高校大学生金相大赛的实验室，金相大赛秘书处设在该校，拥有金相打磨实验室与 3D 打印实验室。",
                    highlights: [
                        "机械 VR 实训中心 · 发动机检测中心",
                        "自动控制综合实验室 · 电气实验室",
                        "材料基础研究中心：金相大赛秘书处设在该校",
                        "金相打磨实验室 · 3D 打印实验室",
                    ],
                    accentHex: "8E5BC9"),
                FacilitySection(
                    title: "学院中心 · 信息与商科",
                    subtitle: "信创大数据 · 新商贸实训",
                    desc: "信创与大数据学院实验中心分设工程训练中心与实验楼：智能云实验室（电子信息、计算机方向）、1203 电子创新实验室、12 个专业实验室、5 个在建学生应用创新实验室（电子数据取证、信息安全与密码技术等），并建有区块链实验室。商学院新商贸综合实训中心为校级示范实验中心：整层约 1500㎡、七大实验室，支撑八大专业五十余门课程、服务四千多名学生，配备近千台设备与 40 余款软件平台。",
                    highlights: [
                        "区块链实验室 · 智能云实验室 · 1203 电子创新实验室",
                        "云财务综合实训室：财务分析 · 中级财务会计 · 财务管理实训",
                    ],
                    accentHex: "0E9AA7",
                    infoPairs: [
                        FacilityInfoPair(label: "新商贸实训中心", value: "约 1500㎡ · 七大实验室 · 设备 2000 余万元"),
                        FacilityInfoPair(label: "信创学院", value: "专业实验室 12 个 · 在建创新实验室 5 个"),
                    ]),
                FacilitySection(
                    title: "模拟机舱与特色平台",
                    subtitle: "A330 实训基地 · 民航技能大赛",
                    desc: "艺术学院航空服务艺术与管理专业与企业共建 A330 实训基地，配备模拟训练机舱（校园平面图注记「民航实训模拟舱」），提供真实场景教学；2024 年 6 月学校与北京广慧金通教育集团联合主办第三届山西省高等学校民航技能大赛，山西 8 所院校参赛。文法学院建有模拟法庭、法律诊所与物证技术实验室；音乐教育专业配备琴房与舞台。",
                    highlights: [
                        "A330 实训基地 · 模拟训练机舱（校企共建）",
                        "2024 第三届山西省高校民航技能大赛：我校主办",
                        "模拟法庭 · 法律诊所 · 物证技术实验室",
                        "音乐教育：琴房 · 舞台",
                    ],
                    accentHex: "C8102E"),
                FacilitySection(
                    title: "科普与创新",
                    subtitle: "2026 全国科普月 · 西门子产线",
                    desc: "2026 年 9 月 20 日，智能制造与车辆学院在工程训练中心举办全国科普月「智行未来·驱动创新」活动：机械 VR 实训中心通过桌面 VR 一体机「钻」进汽车内部拆解发动机；新能源汽车实训中心展示「解剖」比亚迪电动车（动力电池、驱动电机、电气电路、充电系统四大核心）；智能装备与系统实验室现场演示西门子离散行业智能制造综合实训系统全自动流程，机械臂精准完成螺栓装配与颜色分拣。",
                    highlights: [
                        "桌面 VR 一体机：拆解发动机 · 观察活塞运动",
                        "「解剖」比亚迪电动车：四大核心系统直观展示",
                        "西门子智能制造产线：供料 → 检测 → 装配 → 分拣",
                    ],
                    accentHex: "C8A24B"),
                FacilitySection(
                    title: "人才与成果",
                    subtitle: "1100 余项获奖 · 272 项省级项目",
                    desc: "师生在全国各级各类竞赛中获奖 1100 余项；承担省级教改项目、大学生创新训练计划项目 272 项，产学研合作项目 26 项；发表科研论文 259 篇（高水平期刊 16 篇）。《数字电子技术》为省级精品共享课程，学校为山西省高等学校精品共享课程和省级教学成果奖获奖单位。",
                    highlights: [],
                    accentHex: "2B7A5F",
                    infoPairs: [
                        FacilityInfoPair(label: "竞赛获奖", value: "1100 余项"),
                        FacilityInfoPair(label: "省级教改 · 大创项目", value: "272 项"),
                        FacilityInfoPair(label: "产学研合作", value: "26 项"),
                        FacilityInfoPair(label: "科研论文", value: "259 篇（高水平 16 篇）"),
                    ]),
                FacilitySection(
                    title: "管理与联系",
                    subtitle: "实践教学管理处（工程训练中心）",
                    desc: "实验实训体系由「实践教学管理处（工程训练中心）」统筹管理，官方公众号为「山西晋中理工学院躬行实践工作室」（与图书馆、各学院并列于学校官网机构入口）。实验室安全有实证——保卫处与工程实训中心联合开展消防应急演练。需要了解具体房间、设备与开放时间，可直接联系该处。",
                    highlights: [
                        "实验室开放 · 活动通知 → 关注公众号「躬行实践工作室」",
                        "保卫处与工程实训中心联合消防应急演练",
                    ],
                    accentHex: "6B7280",
                    infoPairs: [
                        FacilityInfoPair(label: "联系电话", value: "0354-2459191（边老师）"),
                        FacilityInfoPair(label: "投稿邮箱", value: "jlxkjs@163.com"),
                    ]),
             ]),
    Facility(name: "食堂", icon: "fork.knife",
             desc: "学校共设 3 个食堂——田园餐厅、沧海餐厅、1979 餐厅（1979 餐吧），另有南、北两条商业街作为餐饮补充区。食堂与商业街合计可同时容纳约 20000 人就餐。",
             details: [],
             sections: [
                FacilitySection(
                    title: "田园餐厅",
                    subtitle: "毗邻教学主楼 · 音乐喷泉广场",
                    desc: "靠近教学主楼与音乐喷泉广场一侧，出门即是广场，门口设有超市。官方口径共 2 层、51 个窗口、约 3000 个餐位，早中晚三餐全覆盖。",
                    highlights: [
                        "2 层 · 51 个窗口 · 约 3000 餐位",
                        "特色：塔斯汀中国汉堡（1 层 21 号）",
                        "包子 · 盖饭 · 牛肉丸子面 · 饸烙面",
                        "门口超市 · 紧邻音乐喷泉广场",
                    ],
                    accentHex: "3A9D5C"),
                FacilitySection(
                    title: "沧海餐厅",
                    subtitle: "学生公寓楼群之间 · 人气最高",
                    desc: "坐落学生公寓楼群之间，是校内人气最高的食堂。官方口径共 3 层、65 个窗口、约 4000 个餐位；地下室为生活配套区。",
                    highlights: [
                        "3 层 · 65 个窗口 · 约 4000 餐位",
                        "一楼：常规餐",
                        "二楼：麻辣烫 · 凉皮 · 晋南饼子",
                        "三楼：自助餐，同学聚会首选",
                        "地下室：超市 · 打印店 · 快递点 · 健身房",
                    ],
                    accentHex: "2A6FDB"),
                FacilitySection(
                    title: "1979 餐厅（1979 餐吧）",
                    subtitle: "中等规模 · 早餐品类齐全",
                    desc: "校内规模最精致的中等餐厅，共 3 层、约 80 张餐桌、约 500 个餐位，可满足约 1000 人同时就餐。一楼有麻辣香锅、汉堡、运城名吃，二楼环境雅致。",
                    highlights: [
                        "3 层 · 约 80 张餐桌 · 约 500 餐位",
                        "一楼：麻辣香锅 · 汉堡 · 运城名吃",
                        "二楼：环境雅致，适合聚餐放松",
                        "早餐：油条 · 豆腐脑 · 麻团 · 小笼包 · 粥品 · 馄饨 · 丸子汤 · 特色饼子",
                    ],
                    accentHex: "C8A24B"),
                FacilitySection(
                    title: "北商业街",
                    subtitle: "餐饮补充区",
                    desc: "食堂之外的餐饮补充。北商业街共 17 家门店、50 家商户、约 600 个餐位，可同时满足约 2000 人就餐，米、面、粉、饺子与各类小吃齐全。",
                    highlights: [
                        "17 家门店 · 50 家商户 · 约 600 餐位",
                        "可同时满足约 2000 人就餐",
                    ],
                    accentHex: "E07B39"),
                FacilitySection(
                    title: "南商业街",
                    subtitle: "餐饮补充区",
                    desc: "南商业街共 19 家门店、30 家商户、约 600 张餐桌，可同时满足约 2000 人就餐，米、面、粉、饺子与各类小吃齐全。",
                    highlights: [
                        "19 家门店 · 30 家商户 · 约 600 张餐桌",
                        "可同时满足约 2000 人就餐",
                    ],
                    accentHex: "8E5BC9"),
                FacilitySection(
                    title: "营业时间（参考）",
                    subtitle: "仅供参考",
                    desc: "6:30-22:00（参考值，具体以各餐厅当日公示为准）。",
                    highlights: [],
                    accentHex: "6B7280"),
             ]),
    Facility(name: "体育场馆", icon: "sportscourt.fill",
             desc: "以主体育场（田径场）为核心、篮球为重点项目、室外场地为主体的实用型校园体育体系：主体育场、足球场、主/后篮球场、排球场。2023—2026 连续四届春季运动会在此举办，2026 年启动 327.70 万元运动场安全改造。",
             details: [],
             sections: [
                FacilitySection(
                    title: "主体育场",
                    subtitle: "全校体育活动核心场地",
                    desc: "综合性田径场（内设足球场），学校宣传中的「红色塑胶跑道，条条跑线跃然于上」即坐落于此。历年新生开学典礼暨军训动员、总结表彰，2023—2026 年连续四届春季运动会及足球、田径日常教学锻炼均在主体育场举行，是全校唯一中心场地。",
                    highlights: [
                        "红色塑胶跑道（校园宣传文案）",
                        "内设足球场 · 正常使用",
                        "田赛设施：铅球 · 跳远 · 跳高 · 前抛实心球",
                        "2026 校运会报道确认设有观众席、裁判员、志愿者",
                    ],
                    accentHex: "3A9D5C",
                    infoPairs: [
                        FacilityInfoPair(label: "场地类型", value: "综合性田径场（内设足球场）"),
                        FacilityInfoPair(label: "跑道材质", value: "塑胶 · 校园宣传「红色塑胶跑道」"),
                        FacilityInfoPair(label: "核心承载", value: "校运会 · 军训 · 典礼 · 集会"),
                    ]),
                FacilitySection(
                    title: "2026 运动场改造",
                    subtitle: "安全改造项目 · 预算 327.70 万元",
                    desc: "2026 年 5 月 28 日中国政府采购网公告「2026 年校内基础设施保障维修工程—运动场安全改造项目」，预算 327.70 万元（最高限价 327.662917 万元），对操场运动场等的塑胶跑道、草坪、地下管网进行维修。截至 2026 年 9 月 25 日未见完工公告，故表述为「维修进行中」而非「已完成」。",
                    highlights: [
                        "4 月 23—24 日春季运动会先于 5 月 28 日改造公告举办",
                    ],
                    accentHex: "E07B39",
                    infoPairs: [
                        FacilityInfoPair(label: "项目名称", value: "校内基础设施保障维修工程—运动场安全改造"),
                        FacilityInfoPair(label: "公告平台", value: "中国政府采购网（2026-05-28）"),
                        FacilityInfoPair(label: "预算金额", value: "327.70 万元"),
                        FacilityInfoPair(label: "维修内容", value: "塑胶跑道 · 草坪 · 地下管网"),
                    ]),
                FacilitySection(
                    title: "球类场地",
                    subtitle: "平面图注记四类场地 · 篮球为重点",
                    desc: "校园平面图注记可见「操场、篮球场、足球场、排球场」四类场地。篮球分为主篮球场与后篮球场两处；主体育场内足球场正常使用并已纳入 2026 年维修范围，而校园后部近图书馆的后足球场已停用（学生实地探访：踢足球均在主体育场）。排球项目仅确证平面图注记，数量与材质未公开；学校 2024 年组队参加晋中大学生运动会羽毛球比赛，但未证实持有独立羽毛球馆。",
                    highlights: [
                        "主篮球场 · 后篮球场（学生实地探访确认两处）",
                        "主体育场内足球场：正常使用 · 纳入 2026 维修",
                        "后足球场（近图书馆）：已停用（学生实地探访）",
                        "羽毛球：有参赛队伍，无独立羽毛球馆证据",
                    ],
                    accentHex: "2A6FDB",
                    infoPairs: [
                        FacilityInfoPair(label: "平面图注记", value: "操场 · 篮球场 · 足球场 · 排球场"),
                        FacilityInfoPair(label: "篮球场分区", value: "主篮球场 · 后篮球场"),
                    ]),
                FacilitySection(
                    title: "春季运动会",
                    subtitle: "2023—2026 连续四届 · 年度传统",
                    desc: "春季运动会已连续举办四届（2023 年首届），组织体系成熟：由体育运动委员会主办，学生发展处、校团委、教务处与体育教研部承办，设学生组与教工组，开闭幕式有文体社团献演（舞龙、中国鼓、团体操、武术、啦啦操、舞蹈等）。",
                    highlights: [
                        "2026（4.23-24）：26 个学生项目 · 12 个教工项目（女子仰卧起坐 · 男子 3000 米等）",
                        "2025（4.24）：体育场开幕 · 中国鼓/团体操/舞蹈/武术",
                        "2024（4.25-26，田径场）：100-1500 米 · 接力 · 跳高跳远 · 铅球 · 前抛实心球",
                        "2023（5.18 首届）：体育场开幕式 · 舞龙/校歌/武术/啦啦操",
                    ],
                    accentHex: "C8102E"),
                FacilitySection(
                    title: "篮球荣耀",
                    subtitle: "市级双第三 · 省级第四",
                    desc: "篮球是竞技成果最完整的项目：2023 年晋中市第六届运动会「新元杯」大学生组篮球赛男女篮双双第三名；同年山西省大学生篮球锦标赛男篮斩获第四名（小组第一晋级八强）；2025 年 4 月前女篮国家队中锋魏伟携山西星动力篮球队进校交流，现场球场互动。",
                    highlights: [
                        "2023 晋中市「新元杯」：男篮第三 · 女篮第三",
                        "2023 山西省大学生篮球锦标赛：男篮第四名",
                        "2025.4 前女篮国手魏伟 · 山西星动力篮球队进校交流",
                        "校内赛事：首届「硕成挑战杯」· 大四毕业篮球赛",
                    ],
                    accentHex: "C8A24B"),
                FacilitySection(
                    title: "定向越野",
                    subtitle: "全国锦标赛 · 载誉归来",
                    desc: "无线电测向与定向越野是学校特色竞技项目：2023 年参加山西省青少年无线电测向、定向越野比赛获奖；2025 年在全国锦标赛「载誉归来」（学校官网 2025-12-25 报道），是公开渠道可确认的首支在全国性赛事中获奖的竞技队伍；2025 年 4 月举办第一届校园定向越野赛。",
                    highlights: [
                        "2025 全国锦标赛：载誉归来（官网报道）",
                        "2023 山西省青少年赛获奖",
                        "2025.4 第一届校园定向越野赛",
                    ],
                    accentHex: "8E5BC9"),
                FacilitySection(
                    title: "教学与组织",
                    subtitle: "体育教研部 · 体育运动委员会",
                    desc: "体育教学由通识教育学院体育教研部承担（学院下设思想政治理论教研部、理学教研部、体育教研部、人文素养教研部）；校级体育赛事由体育运动委员会主办。学校建有国旗护卫队，承担升旗与军训仪式任务。",
                    highlights: [
                        "国旗护卫队：升旗与军训仪式任务（官网「映像校园」专栏）",
                    ],
                    accentHex: "0E9AA7",
                    infoPairs: [
                        FacilityInfoPair(label: "归属部门", value: "通识教育学院 · 体育教研部"),
                        FacilityInfoPair(label: "运动会主办", value: "体育运动委员会"),
                        FacilityInfoPair(label: "军训与典礼", value: "2026 级 9.11 动员 · 9.19 表彰（体育场）"),
                    ]),
                FacilitySection(
                    title: "体测与毕业",
                    subtitle: "国家学生体质健康标准",
                    desc: "按《国家学生体质健康标准（2014 年修订）》执行：学生体质健康达标、修满体育学分方可毕业；因病或残疾可向学校申请暂缓或免予执行；成绩达到良好及以上者方可参加评优与评奖。本校年度体测时间、地点、预约与补测安排以当年学校通知为准。",
                    highlights: [],
                    accentHex: "4C6EF5",
                    infoPairs: [
                        FacilityInfoPair(label: "毕业要求", value: "体测达标 + 修满体育学分"),
                        FacilityInfoPair(label: "评优评奖", value: "成绩良好及以上（国家标准）"),
                        FacilityInfoPair(label: "免测政策", value: "因病或残疾可申请暂缓/免予"),
                    ]),
                FacilitySection(
                    title: "周边配套",
                    subtitle: "紧邻高铁站 · 生活便利",
                    desc: "主体育场（大操场）附近有瑞幸咖啡与一排饭店（学生实地探访），通往「前商」商业区方向；学校紧邻高铁晋中站，学生实测步行约十分钟；公交乘榆次 9 路在「华澳学院站」下车，学校位于站东 300 米。",
                    highlights: [
                        "操场附近：瑞幸咖啡 · 一排饭店（学生实地探访）",
                        "高铁晋中站：步行约 10 分钟（学生实测）",
                        "公交：榆次 9 路「华澳学院站」东 300 米",
                    ],
                    accentHex: "2B7A5F"),
                FacilitySection(
                    title: "温馨提示",
                    subtitle: "以当年校内通知为准",
                    desc: "跑道周长与道数、看台容量、篮球场精确块数与材质、场馆开放时间、器材借用规则、体育课项目与学分、体测具体安排等校园执行细节尚未公开，App 不作臆测。入学后请以当年校内通知、体育教研部公告与现场导视为准。",
                    highlights: [
                        "场馆开放 · 器材借用 → 咨询体育教研部",
                        "体测安排 · 体育课选修 → 以当年通知为准",
                        "跑道规格 · 看台容量 · 场地块数 → 未公开，不臆测",
                    ],
                    accentHex: "6B7280"),
             ]),
    Facility(name: "学生公寓", icon: "house.fill",
             desc: "以山西省发改委批复为定价基座（晋发改收费发〔2023〕197号）：「学生公寓楼」共 14 栋已建成（1—12、15、16 号）+ 2 栋新建（29#、30#），四档收费 1450/1350/1250/1150 元·生/年，12 栋拥有世界名校别名，29#、30# 是全校唯一配备电梯的宿舍楼。",
             details: [],
             sections: [
                FacilitySection(
                    title: "正规名称与别名",
                    subtitle: "学生公寓楼 · 12 栋世界名校别名",
                    desc: "正式管理名称「学生公寓楼」（山西省发改委批复附件口径），学校官方简称「山西理工」。1—12 号楼中 12 栋拥有别名：11 个取自世界知名大学——英国 4 栋（华威2、剑桥5、约克7、利兹8）、美国 3 栋（哈弗6、斯坦福10、耶鲁12）、澳大利亚 2 栋（悉尼4、科廷9）、德国 1 栋（海德1），雨轩3 为唯一中文命名。命名背景为学校同 100 余所海外高校开展双学位/本升硕合作，是全国「十大阳光留学」基地。",
                    highlights: [
                        "海德1 · 华威2 · 雨轩3 · 悉尼4 · 剑桥5 · 哈弗6",
                        "约克7 · 利兹8 · 科廷9 · 斯坦福10 · 耶鲁12",
                        "6 号楼为「哈弗」非「哈佛」（地图 POI 登记写法）",
                        "别名体系仅见于地图 POI：以官方楼号为准",
                    ],
                    accentHex: "2A6FDB",
                    infoPairs: [
                        FacilityInfoPair(label: "官方简称", value: "山西理工（章程）"),
                        FacilityInfoPair(label: "英文名", value: "Shanxi Jinzhong Institute of Technology"),
                    ]),
                FacilitySection(
                    title: "楼栋规模",
                    subtitle: "14 栋已建成 + 2 栋新建",
                    desc: "已建成 14 栋：1—12 号（12 栋）加 15、16 号；另新建 29#、30#。目前无任何公开证据表明 13、14 号楼存在（省发改委文件未列、地图无 POI），学校大概率跳过这两个编号，但在取得学校建筑清册前不作绝对表述；17—28 号同样无公开证据。全校全日制在校生 16945 余人（2026 年官网）。",
                    highlights: [
                        "旧宿舍区：前排 1-5 号（近前商）· 中部 6-10 号 · 后部 11/12/15/16 号（近沧海食堂）",
                        "新宿舍区：29#、30# 位于校园西北/北侧最深处",
                        "教师公寓别名「儒韵」：校园东南部，与学生公寓分开",
                        "宿舍区步行至南门约 5—8 分钟",
                    ],
                    accentHex: "3A9D5C",
                    infoPairs: [
                        FacilityInfoPair(label: "已建成", value: "14 栋（1—12、15、16 号）"),
                        FacilityInfoPair(label: "新建", value: "29#、30#（2024 年项目）"),
                        FacilityInfoPair(label: "在校生", value: "16945 余人（2026 官网）"),
                    ]),
                FacilitySection(
                    title: "四档收费",
                    subtitle: "晋发改收费发〔2023〕197号 · 2023 秋执行",
                    desc: "山西省发改委、教育厅《关于山西晋中理工学院学生公寓住宿费收费标准的批复》（晋发改收费发〔2023〕197号，2023 年 6 月 8 日），自 2023 年秋季学期执行，实行「新生新办法、老生老办法」（2022 级住宿费 1000 元/年）。分档按面积、卫浴、床具与楼层设施，而非新楼/旧楼或性别。",
                    highlights: [
                        "A 档 1450 元/生·年：4 人间·独卫 32.57㎡·上床下桌 → 1、4、7 号",
                        "B 档 1350 元/生·年：6 人间·独卫 32.57㎡·两连三人位床具 → 1、4、7 号",
                        "C 档 1250 元/生·年：6 人间·公卫 31.8㎡·两连三人位床具 → 2/3/5/6/8/9/10/11/12/15/16 号",
                        "D 档 1150 元/生·年：6 人间·公卫 31.8㎡·高架床（上下床）→ 同上",
                    ],
                    accentHex: "E07B39",
                    infoPairs: [
                        FacilityInfoPair(label: "批复文号", value: "晋发改收费发〔2023〕197号"),
                        FacilityInfoPair(label: "执行时间", value: "2023 年秋季学期"),
                        FacilityInfoPair(label: "面积口径", value: "房间使用面积（非建筑面积）"),
                    ]),
                FacilitySection(
                    title: "室内配置与卫浴",
                    subtitle: "独卫 ≠ 热水淋浴",
                    desc: "所有档位均含独立阳台；床具、桌椅、储物（衣物柜、书架）列入政府文件；楼内网络全覆盖（自行办理校园网/宽带，可路由器全宿舍共享）。最重要提醒：宿舍内无热水，楼层公共洗漱间仅供应冷水；1、4、7 号楼虽有独立卫生间，同样无热水淋浴——洗澡需到公共澡堂（位于沧海食堂附近）。空调未列入批复固定设施，是否统一租赁、租金与覆盖楼栋均无官方依据。",
                    highlights: [
                        "1/4/7 号：独立卫生间（但无热水淋浴）",
                        "洗澡 → 公共澡堂（沧海食堂附近）",
                        "网络：楼内全覆盖 · 宽带自办",
                        "学生证实所有宿舍均有暖气（山西集中供暖）",
                    ],
                    accentHex: "C8102E"),
                FacilitySection(
                    title: "楼层配套与门禁",
                    subtitle: "22:30 关门 → 23:00 断电 → 23:30 熄灯",
                    desc: "每栋楼配纯净水饮水机（新楼每层一台、靠电梯一侧）、共享吹风机与洗衣机（新楼洗衣房集中一楼两间）；设专职门卫传达室、辅导员值班室、保洁与消防专职人员。作息三环节（学生口径）：22:30 门禁锁门、23:00 断电（周五六 24:00）、23:30 统一熄灯，晚归需向宿管报备登记。禁用大功率电器（寝室内使用吹风机会跳闸，可在卫生间公共插头或洗衣房使用）；禁止饲养宠物。",
                    highlights: [
                        "22:30 关门 → 23:00 断电（周五六 24:00）→ 23:30 熄灯",
                        "限电功率约 500W（800W 一说）· 未取得用电规定原文",
                        "不断网 · 暑期宿舍与自习室开放",
                        "楼内监控 · 自助售卖机 · 垃圾投放区",
                    ],
                    accentHex: "4C6EF5",
                    infoPairs: [
                        FacilityInfoPair(label: "楼层配置", value: "饮水机 · 共享吹风机 · 洗衣机（文件口径）"),
                        FacilityInfoPair(label: "工作人员", value: "专职门卫 · 辅导员值班 · 保洁 · 消防专职"),
                    ]),
                FacilitySection(
                    title: "新建公寓 29#、30#",
                    subtitle: "全校唯一电梯公寓 · 18805.02㎡",
                    desc: "与晋澳国际高科技创新楼、教学实验楼、专家教学科研楼同批五单体（总建筑面积 44451.31㎡，五单体工程造价约 2.85 亿元）。29# 9280.67㎡、30# 9524.35㎡，两栋公寓合计 18805.02㎡。规划许可证发证 2024 年 8 月 30 日（批后公示发布 2024-09-01）；规划核验（验收）申报 2025 年 12 月 29 日。2026 年 7 月电梯设备到货（学生口径），为全校唯二配备电梯的宿舍楼；预计新增约 3000 床位（待核）。",
                    highlights: [
                        "户型：六人间上床下桌 · 每人一柜一桌 · 无室内阳台",
                        "每层两个大晾衣阳台 · 洗衣房集中一楼两间 · 电梯",
                        "位置：校园西北最深处（距教学楼较远）",
                        "规划核验 ≠ 已交付：配置与收费以新批复为准",
                    ],
                    accentHex: "0E9AA7",
                    infoPairs: [
                        FacilityInfoPair(label: "两栋公寓合计", value: "18805.02㎡"),
                        FacilityInfoPair(label: "规划许可", value: "2024-08-30 发证"),
                        FacilityInfoPair(label: "验收申报", value: "2025-12-29"),
                    ]),
                FacilitySection(
                    title: "快递与周边",
                    subtitle: "四站点快递 · 出校门 800 米高铁站",
                    desc: "快递四站点：校内菜鸟驿站（主教学楼左拐往操场方向，顺丰/京东/韵达/德邦/申通）、邮政快递点（沧海餐厅下方/澡堂对面，EMS）、顺丰速运理工站（校内驿站 41 号货架）、校外菜鸟驿站（出校门对面，京东/多多买菜等）。支持外卖送餐到寝（学生口径）。",
                    highlights: [
                        "校内商业：瑞幸 · 蜜雪冰城 · 沪上阿姨 · 茶百道 · 塔斯汀 · 库迪 · 好想来 · 赵一鸣零食 · 美甲店 · 理发店 · 音乐餐厅",
                        "出校门：小吃街 · 公交站 · 健身房 · 眼镜店 · 台球厅",
                        "出校门约 800 米：高铁晋中站",
                        "宿舍区紧邻沧海食堂与洗澡堂",
                    ],
                    accentHex: "2B7A5F",
                    infoPairs: [
                        FacilityInfoPair(label: "快递点", value: "校内菜鸟 · 邮政 · 顺丰理工站 · 校外菜鸟"),
                        FacilityInfoPair(label: "通讯地址", value: "晋中市榆次区张庆乡创业街839号"),
                    ]),
                FacilitySection(
                    title: "入住与管理",
                    subtitle: "智慧迎新 · 随机「开盲盒」",
                    desc: "住宿费实行分类标准 + 收费公示，学校不得擅自提高收费标准或扩大收费范围，应在招生简章和校园显著位置公示收费项目、标准、依据和监督电话。宿舍信息已电子化：智慧迎新系统可查看班级、宿舍、缴费情况（不等于新生能自选房间）。新生分配为随机「开盲盒」，按专业/班级统一划分、同班寝室提前固定（学生口径）。",
                    highlights: [
                        "报到动线：扫码签到 → 迎新专车运行李 → 前篮球场寄存 → 凭编码领取",
                        "智慧迎新扫码 → 宿管处领取钥匙",
                        "12、15 号楼在校园较后侧 · 11 号楼在对面 · 沧海食堂最近",
                    ],
                    accentHex: "8E5BC9",
                    infoPairs: [
                        FacilityInfoPair(label: "分配方式", value: "随机「开盲盒」（学生口径）"),
                        FacilityInfoPair(label: "迎新系统", value: "智慧迎新（班级/宿舍/缴费）"),
                    ]),
                FacilitySection(
                    title: "学生体验",
                    subtitle: "空间宽裕 · 唯一硬伤：无热水",
                    desc: "优点：4 人间 32.57㎡/6 人间 31.8㎡ 在同档民办院校中不算局促；上床下桌档人均空间宽裕；楼层饮水机、吹风机、洗衣机与网络全覆盖；分档按设施相对公平；户型多样（上床下桌、三连桌、新旧楼可选）；10 号楼楼下即商铺食堂、离教学楼最近；29/30# 有电梯；外卖送寝、校内商业丰富。不足：宿舍内无热水、洗澡必须去公共澡堂——这是体验上最大的硬伤；高温季空调不确定；1—16 号楼均无电梯；新楼位置偏僻。",
                    highlights: [
                        "10 号楼（斯坦福10栋）：楼下即商铺和食堂 · 离教学楼最近",
                        "29#、30#：设施最新（电梯）但距教学楼远",
                        "所有宿舍有暖气",
                        "门卫 · 辅导员值班室 · 保洁 · 消防专职人员",
                    ],
                    accentHex: "C8A24B"),
                FacilitySection(
                    title: "温馨提示",
                    subtitle: "入学前五个必问",
                    desc: "空调官方依据、限电规定原文、门禁确切时间、房间细节参数（床具尺寸/插座/网口）、29/30# 收费标准与是否正式启用等均未公开，App 不作臆测。建议入学前索取当年《入学须知》与收费公示，入学后向辅导员索取现行《学生手册》逐条核实。",
                    highlights: [
                        "我的房间属 1450 / 1350 / 1250 / 1150 哪一档？",
                        "独卫是否有淋浴？（已知全校宿舍内均无热水）",
                        "空调是否预装、需租赁、费用多少？",
                        "我分到的楼是否有电梯（29#/30#），还是位置好的旧楼？",
                    ],
                    accentHex: "6B7280"),
             ]),
]

// MARK: - 发展历程

struct TimelineEvent: Identifiable, Codable {
    var id: String { year + event }
    let year: String
    let event: String
}

let defaultTimeline: [TimelineEvent] = [
    TimelineEvent(year: "2002", event: "中北大学信息商务学院成立"),
    TimelineEvent(year: "2021", event: "转设为山西晋中理工学院"),
    TimelineEvent(year: "2023", event: "获批全国健康学校建设单位"),
    TimelineEvent(year: "2025", event: "马克思主义学院成立"),
    TimelineEvent(year: "2025", event: "山西省民办大学排名第1（校友会）"),
    TimelineEvent(year: "2026", event: "持续推进高质量发展"),
]

// MARK: - 快捷链接

struct QuickLink: Identifiable, Codable {
    let id = UUID()
    let title: String
    let icon: String

    enum CodingKeys: String, CodingKey {
        case title, icon
    }
}

let quickLinks: [QuickLink] = [
    QuickLink(title: "院系查询", icon: "building.2.fill"),
    QuickLink(title: "新闻资讯", icon: "newspaper.fill"),
    QuickLink(title: "校园荣誉", icon: "trophy.fill"),
    QuickLink(title: "校园服务", icon: "square.grid.2x2.fill"),
    QuickLink(title: "招生就业", icon: "person.crop.circle.badge.plus"),
    QuickLink(title: "学校概况", icon: "info.circle.fill"),
]

// MARK: - 友情链接

struct FooterLink: Identifiable, Codable {
    var id: String { name }
    let name: String
    let href: String
}

// MARK: - 社交平台

struct SocialPlatform: Identifiable, Codable {
    var id: String { title }
    let title: String
    let img: String
}

// MARK: - 招生网（ZSW）数据模型

/// 招生网文章条目
struct ZSWArticle: Identifiable, Codable {
    var id: String { articleId ?? UUID().uuidString }
    let articleId: String?
    let title: String
    let description: String
    let imageUrl: String?
    let updateTime: String?
    let tag: String?

    enum CodingKeys: String, CodingKey {
        case articleId = "id"
        case title, description, tag
        case imageUrl = "image_url"
        case updateTime = "update_time"
    }
}

/// 招生网栏目（招生计划、招生公告、招生动态等）
struct ZSWSection: Identifiable, Codable {
    let id: String
    let columnId: String
    let titleCn: String
    let titleEn: String
    let componentType: String
    let articles: [ZSWArticle]
}

/// 报考指南子栏目（奖励政策、报考攻略、入学须知、来校路线）
struct ZSWGuideChild: Identifiable, Codable {
    let id: String
    let columnId: String
    let titleCn: String
    let titleEn: String
    let articles: [ZSWArticle]
}

/// 首页三栏目（录取查询、历年分数线、专业介绍）
struct ZSWRecruitItem: Identifiable, Codable {
    let id: String
    let titleCn: String
    let titleEn: String
    let href: String
    let imageUrl: String?
    let isOut: Bool
    let articles: [ZSWArticle]
}

/// 招生网首页完整数据
struct ZSWHomeData: Codable {
    let siteId: String
    let recruitItems: [ZSWRecruitItem]       // 录取查询、历年分数线、专业介绍
    let enrollmentPlan: ZSWSection?           // 招生计划
    let notices: ZSWSection?                  // 招生公告
    let guideChildren: [ZSWGuideChild]        // 报考指南子栏目
    let enrollmentNews: ZSWSection?           // 招生动态
}

// MARK: - 收藏文章

/// 收藏文章数据模型 —— 本地持久化，仅缓存基础信息 + 缩略图
struct BookmarkItem: Identifiable, Codable, Equatable, Hashable {
    var id: String { readKey }
    let title: String
    let date: String
    let category: String
    let summary: String
    let imageUrl: String?
    let articleId: String?
    let href: String?
    let author: String?
    let source: String?
    let columnId: String?
    let bookmarkDate: Date          // 收藏时间
    var cachedContent: String?     // 离线缓存的正文（可选）
    var contentCached: Bool        // 正文是否已缓存
    /// 最近一次打开时间（「最近阅读」排序 / 状态展示；旧数据缺省为 nil）
    var lastViewedAt: Date?
    /// 检测到官网原文更新、尚未打开确认的时间（非空 → 展示「内容有更新」徽标）
    var updateDetectedAt: Date?

    /// 是否有待确认的内容更新（派生展示状态）
    var hasPendingUpdate: Bool { updateDetectedAt != nil }

    /// 已读状态唯一键
    var readKey: String { articleId ?? title + date }

    /// 智能构造原文链接
    var originalArticleURL: String {
        if let href = href, !href.isEmpty, href != "/",
           let url = URL(string: href),
           url.scheme == "http" || url.scheme == "https" {
            return href
        }
        if let href = href, !href.isEmpty, href != "/", href.hasPrefix("/") {
            return SchoolInfo.website + href
        }
        if let articleId = articleId, !articleId.isEmpty {
            return "\(SchoolInfo.website)/#/list/article?id=\(articleId)"
        }
        return SchoolInfo.website
    }

    init(from news: NewsItem) {
        self.title = news.title
        self.date = news.date
        self.category = news.category
        self.summary = news.summary
        self.imageUrl = news.imageUrl
        self.articleId = news.articleId
        self.href = news.href
        self.author = news.author
        self.source = news.source
        self.columnId = news.columnId
        self.bookmarkDate = Date()
        self.cachedContent = nil
        self.contentCached = false
        self.lastViewedAt = nil
        self.updateDetectedAt = nil
    }

    init(title: String, date: String, category: String, summary: String, imageUrl: String? = nil, articleId: String? = nil, href: String? = nil, author: String? = nil, source: String? = nil, columnId: String? = nil, bookmarkDate: Date = Date(), cachedContent: String? = nil, contentCached: Bool = false, lastViewedAt: Date? = nil, updateDetectedAt: Date? = nil) {
        self.title = title
        self.date = date
        self.category = category
        self.summary = summary
        self.imageUrl = imageUrl
        self.articleId = articleId
        self.href = href
        self.author = author
        self.source = source
        self.columnId = columnId
        self.bookmarkDate = bookmarkDate
        self.cachedContent = cachedContent
        self.contentCached = contentCached
        self.lastViewedAt = lastViewedAt
        self.updateDetectedAt = updateDetectedAt
    }

    /// 转换为 NewsItem（用于兼容现有详情页）
    func toNewsItem() -> NewsItem {
        NewsItem(
            title: title, date: date, category: category,
            summary: summary, content: cachedContent ?? summary,
            imageUrl: imageUrl, columnId: columnId,
            articleId: articleId, href: href,
            author: author, source: source
        )
    }
}

// MARK: - 专业介绍

/// 专业介绍 - 专业条目
struct SpecialtyMajor: Identifiable, Codable {
    var id: String { articleId }
    let articleId: String
    let title: String
    let description: String
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case articleId = "id"
        case title, description
        case imageUrl = "image_url"
    }
}

/// 专业介绍 - 学院
struct SpecialtyCollege: Identifiable, Codable {
    let id: String
    let titleCn: String
    let titleEn: String
    let majors: [SpecialtyMajor]

    enum CodingKeys: String, CodingKey {
        case id
        case titleCn = "title_cn"
        case titleEn = "title_en"
        case majors
    }
}

/// 专业介绍 - 完整数据
struct SpecialtyData: Codable {
    let columnId: String
    let titleCn: String
    let colleges: [SpecialtyCollege]

    enum CodingKeys: String, CodingKey {
        case columnId = "column_id"
        case titleCn = "title_cn"
        case colleges
    }
}