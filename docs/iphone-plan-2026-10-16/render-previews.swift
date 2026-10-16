// Design-only native render. No application target, credentials, or live data.
import Foundation
import SwiftUI
import AppKit

private let blue = Color(red: 0.06, green: 0.45, blue: 0.96)
private let green = Color(red: 0.04, green: 0.65, blue: 0.37)
private let red = Color(red: 0.91, green: 0.26, blue: 0.29)
private let ink = Color(red: 0.10, green: 0.15, blue: 0.22)
private let muted = Color(red: 0.47, green: 0.52, blue: 0.59)
private let paper = Color(red: 0.95, green: 0.965, blue: 0.985)
private let amber = Color(red: 0.95, green: 0.65, blue: 0.22)

struct PulseMark: View {
    var color: Color = blue
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 12)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 11, y: 4)); p.addLine(to: CGPoint(x: 15, y: 21))
            p.addLine(to: CGPoint(x: 20, y: 9)); p.addLine(to: CGPoint(x: 26, y: 9))
        }.stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            .frame(width: 27, height: 25)
    }
}
struct Tag: View {
    let text: String
    var color: Color = blue
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
    }
}
struct SmallLine: View {
    var color: Color = green
    var phase = 0.0
    var body: some View {
        Canvas { context, size in
            var line = Path()
            for i in 0..<28 {
                let x = Double(i) / 27
                let y = 0.45 + 0.20 * sin(x * 17 + phase) + 0.12 * cos(x * 34 + phase) + 0.13*x
                let point = CGPoint(x: x * size.width, y: y * size.height)
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1.3)
        }.frame(width: 46, height: 24)
    }
}
struct StockRow: View {
    let name: String, code: String, market: String, price: String, change: String
    var up = false
    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                HStack(spacing: 4) {
                    Tag(text: market)
                    Text(code).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            SmallLine(color: up ? red : green, phase: Double(code.utf8.first ?? 0))
            VStack(alignment: .trailing, spacing: 4) {
                Text(price).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(ink)
                Text(change).font(.system(size: 11, weight: .semibold)).foregroundStyle(up ? red : green)
            }.frame(width: 81, alignment: .trailing)
        }.frame(height: 60)
    }
}
struct Status: View {
    var body: some View {
        HStack {
            Text("10:18").font(.system(size: 12, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "cellularbars"); Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
            }.font(.system(size: 11, weight: .semibold))
        }.padding(.horizontal, 22).frame(height: 38).padding(.top, 5).foregroundStyle(ink)
            .overlay(alignment: .top) { Capsule().fill(.black).frame(width: 109, height: 27).offset(y: 9) }
    }
}
struct Phone<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(width: 336, height: 730).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 37, style: .continuous))
            .overlay(alignment: .bottom) { Capsule().fill(ink).frame(width: 112, height: 4).padding(.bottom, 9) }
            .padding(8).background(Color(red: 0.13, green: 0.15, blue: 0.18), in: RoundedRectangle(cornerRadius: 46))
            .overlay { RoundedRectangle(cornerRadius: 46).stroke(Color.white.opacity(0.45), lineWidth: 1) }
            .shadow(color: ink.opacity(0.12), radius: 18, y: 12)
    }
}
struct Caption: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:20,weight:.semibold)).foregroundStyle(ink); Text(subtitle).font(.system(size:12)).foregroundStyle(muted) }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct Intro: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment:.leading,spacing:11) {
            HStack(spacing:7) { PulseMark(); Text("FFF / iPhone").font(.system(size:14,weight:.semibold)).foregroundStyle(blue) }
            Text(title).font(.system(size:36,weight:.bold)).foregroundStyle(ink)
            Text(subtitle).font(.system(size:15)).foregroundStyle(muted)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct WorkTabs: View {
    let selected: Int
    let items = [("sun.max", "今日"), ("star", "自选"), ("list.bullet.clipboard", "计划"), ("person.crop.rectangle", "账户")]
    var body: some View {
        HStack {
            ForEach(0..<4) { index in
                VStack(spacing:4) {
                    Image(systemName:items[index].0).font(.system(size:17,weight:.medium))
                    Text(items[index].1).font(.system(size:9,weight:.medium))
                }.foregroundStyle(index == selected ? blue : muted).frame(maxWidth:.infinity)
            }
        }.frame(height:51).padding(.top,6).background(.white)
            .overlay(alignment:.top) { Rectangle().fill(ink.opacity(0.08)).frame(height:0.5) }
    }
}
struct WorkHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.system(size:28,weight:.bold))
            Spacer()
            HStack(spacing:5) { Image(systemName:"square.and.pencil"); Text("记交易") }
                .font(.system(size:11,weight:.semibold)).foregroundStyle(blue)
                .padding(.horizontal,10).padding(.vertical,7).background(blue.opacity(0.07),in:Capsule())
        }.padding(.top,17)
    }
}
struct AccountHeader: View {
    var body: some View {
        HStack { Text("示例现金账户  ⌄").font(.system(size:11,weight:.medium)); Spacer(); Image(systemName:"icloud").foregroundStyle(blue); Text("上次同步 10:18").foregroundStyle(muted) }
            .font(.system(size:9)).padding(.top,8)
    }
}
struct AutoBanner: View {
    var body: some View {
        HStack(alignment:.top,spacing:9) {
            PulseMark().scaleEffect(0.75).frame(width:23,height:22)
            VStack(alignment:.leading,spacing:5) {
                Text("自动盯盘已开启").font(.system(size:13,weight:.semibold))
                Text("开盘自动出现 · 持仓与计划驱动").font(.system(size:9)).foregroundStyle(muted)
            }
            Spacer(); Image(systemName:"slider.horizontal.3").font(.system(size:13)).foregroundStyle(blue)
        }.padding(12).background(blue.opacity(0.055),in:RoundedRectangle(cornerRadius:12))
    }
}
struct TodayScreen: View {
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Status().padding(.horizontal,-17)
            WorkHeader(title:"今日")
            AccountHeader()
            AutoBanner().padding(.top,16)
            VStack(alignment:.leading,spacing:6) {
                HStack { Text("账户净资产 · 示例折合人民币").font(.system(size:10)).foregroundStyle(muted); Spacer(); Image(systemName:"eye").font(.system(size:11)).foregroundStyle(muted) }
                Text("¥286,420.00").font(.system(size:31,weight:.semibold,design:.rounded)).monospacedDigit()
                HStack { Text("今日变动").font(.system(size:10)).foregroundStyle(muted); Text("+¥1,350.00").font(.system(size:12,weight:.semibold)).foregroundStyle(red); Spacer(); Text("账户明细 ›").font(.system(size:10)).foregroundStyle(blue) }
            }.padding(.top,18)
            HStack { Text("今日待办").font(.system(size:16,weight:.semibold)); Spacer(); Text("全部计划 ›").font(.system(size:11)).foregroundStyle(blue) }.padding(.top,23)
            VStack(alignment:.leading,spacing:7) {
                HStack { Tag(text:"价格条件到达",color:amber); Spacer(); Text("查看计划 ›").font(.system(size:10)).foregroundStyle(blue) }
                Text("三星电子 · 分批买入").font(.system(size:14,weight:.semibold))
                Text("手工条件待复核，不等于已经成交").font(.system(size:10)).foregroundStyle(muted)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(paper,in:RoundedRectangle(cornerRadius:12)).padding(.top,9)
            HStack(spacing:6) { Image(systemName:"arrow.triangle.2.circlepath").foregroundStyle(amber); Text("1笔本机记录待同步"); Spacer(); Text("查看").foregroundStyle(blue) }
                .font(.system(size:10)).foregroundStyle(muted).padding(.vertical,12)
            HStack { Text("关注行情").font(.system(size:15,weight:.semibold)); Spacer(); Text("自选 ›").font(.system(size:11)).foregroundStyle(blue) }.padding(.top,5)
            StockRow(name:"三星电子",code:"005930",market:"韩",price:"208,000",change:"−10.34%")
            Divider().opacity(0.45)
            StockRow(name:"银行",code:"881155",market:"行业",price:"1,386.064",change:"−1.09%")
            Spacer(minLength:4)
            Text("所有数据为示意 · 非真实账户").font(.system(size:9)).foregroundStyle(muted).padding(.bottom,10)
            WorkTabs(selected:0).padding(.horizontal,-17)
            Spacer().frame(height:25)
        }.padding(.horizontal,17).foregroundStyle(ink)
    }
}
struct PlanCard: View {
    var first = true
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Tag(text:first ? "买入计划" : "卖出计划",color:first ? blue : green)
                Spacer(); Text(first ? "价格条件到达" : "等待价格").font(.system(size:9,weight:.medium)).foregroundStyle(first ? amber : muted)
            }
            Text(first ? "三星电子 · 分批买入" : "苹果 · 分批止盈").font(.system(size:15,weight:.semibold))
            HStack { Text(first ? "目标 ≤ ₩210,000" : "目标 ≥ $245.00"); Spacer(); Text(first ? "计划 300股" : "计划 40股") }.font(.system(size:10)).foregroundStyle(muted)
            HStack { Text(first ? "已记成交 100 / 300股" : "已记成交 0 / 40股"); Spacer(); Text(first ? "33%" : "0%") }.font(.system(size:10)).foregroundStyle(muted)
            GeometryReader { g in ZStack(alignment:.leading) { Capsule().fill(blue.opacity(0.09)); Capsule().fill(blue).frame(width:g.size.width*(first ? 0.333 : 0)) } }.frame(height:4)
            if first {
                HStack(spacing:5) { Image(systemName:"checklist").foregroundStyle(amber); Text("手工条件待复核").foregroundStyle(muted) }.font(.system(size:10))
            }
            HStack {
                Text("详情 / 编辑").font(.system(size:11,weight:.medium)).foregroundStyle(blue)
                    .padding(.horizontal,12).frame(height:30).background(blue.opacity(0.06),in:Capsule())
                Spacer()
                Text("记成交").font(.system(size:11,weight:.semibold)).foregroundStyle(.white)
                    .padding(.horizontal,16).frame(height:30).background(blue,in:Capsule())
            }.padding(.top,2)
        }.padding(13).background(paper,in:RoundedRectangle(cornerRadius:14))
    }
}
struct PlansScreen: View {
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Status().padding(.horizontal,-17)
            WorkHeader(title:"计划")
            AccountHeader()
            HStack(spacing:6) {
                Text("进行中 3").foregroundStyle(blue).padding(.horizontal,12).padding(.vertical,7).background(blue.opacity(0.08),in:Capsule())
                Text("已结算").foregroundStyle(muted).padding(.horizontal,10)
                Text("已放弃").foregroundStyle(muted)
            }.font(.system(size:11,weight:.medium)).padding(.top,17)
            HStack { Text("当前关注").font(.system(size:11)).foregroundStyle(muted); Spacer(); Label("新计划",systemImage:"plus").font(.system(size:11)).foregroundStyle(blue) }.padding(.top,17).padding(.bottom,10)
            PlanCard()
            PlanCard(first:false).padding(.top,12)
            Spacer(minLength:5)
            HStack(alignment:.top,spacing:6) { Image(systemName:"info.circle"); Text("价格到达只提醒；执行进度由真实成交记录计算。").fixedSize(horizontal:false,vertical:true) }.font(.system(size:9)).foregroundStyle(muted).padding(.vertical,10)
            WorkTabs(selected:2).padding(.horizontal,-17)
            Spacer().frame(height:25)
        }.padding(.horizontal,17).foregroundStyle(ink)
    }
}
struct FactRow: View {
    let name: String, value: String
    var body: some View {
        HStack { Text(name).foregroundStyle(muted); Spacer(); Text(value); Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(muted) }.font(.system(size:11)).frame(height:38)
    }
}
struct TradeRecordScreen: View {
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Status().padding(.horizontal,-17)
            HStack { Text("取消").font(.system(size:12)).foregroundStyle(blue); Spacer(); Text("记成交").font(.system(size:17,weight:.semibold)); Spacer(); Text("取消").font(.system(size:12)).hidden() }.padding(.top,18)
            Text("记录已完成的交易，不向券商下单").font(.system(size:10)).foregroundStyle(muted).padding(.top,13)
            VStack(alignment:.leading,spacing:5) {
                Text("实际成交账户").font(.system(size:9)).foregroundStyle(muted)
                HStack { Image(systemName:"lock.fill").font(.system(size:10)).foregroundStyle(blue); Text("示例现金账户").font(.system(size:14,weight:.semibold)); Spacer(); Text("更改").font(.system(size:10)).foregroundStyle(blue) }
                Text("写入账户已固定，避免随全局切换误记").font(.system(size:9)).foregroundStyle(muted)
            }.padding(12).background(paper,in:RoundedRectangle(cornerRadius:12)).padding(.top,15)
            HStack { Text("三星电子").font(.system(size:20,weight:.semibold)); Spacer(); Tag(text:"记录买入") }.padding(.top,17)
            Text("005930.KS · 韩元 / 股").font(.system(size:10)).foregroundStyle(muted).padding(.top,4)
            Text("示例：以下为用户填写的实际成交信息").font(.system(size:9)).foregroundStyle(muted).padding(.top,15)
            HStack(spacing:9) {
                VStack(alignment:.leading,spacing:8) { Text("实际成交价（KRW）").font(.system(size:9)).foregroundStyle(muted); Text("208,000").font(.system(size:23,weight:.medium,design:.rounded)) }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(paper,in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:8) { Text("本次成交数量（股）").font(.system(size:9)).foregroundStyle(muted); Text("100").font(.system(size:23,weight:.medium,design:.rounded)) }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(paper,in:RoundedRectangle(cornerRadius:10))
            }.padding(.top,7)
            VStack(spacing:0) {
                FactRow(name:"成交日期",value:"10月16日")
                Divider().opacity(0.4)
                FactRow(name:"费用（KRW）",value:"0.00")
                Divider().opacity(0.4)
                FactRow(name:"资金方式",value:"自有资金")
                Divider().opacity(0.4)
                FactRow(name:"关联计划",value:"三星电子分批买入")
            }.padding(.top,9)
            VStack(alignment:.leading,spacing:6) {
                Text("保存前核对").font(.system(size:11,weight:.semibold))
                Text("计划已记：100 → 200 / 300股").font(.system(size:10)).foregroundStyle(muted)
                Text("剩余计划：100股 · 不是自动完成计划").font(.system(size:10)).foregroundStyle(muted)
                Text("资金影响：−₩20,800,000（示意）").font(.system(size:10)).foregroundStyle(muted)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(blue.opacity(0.05),in:RoundedRectangle(cornerRadius:11)).padding(.top,10)
            Spacer(minLength:5)
            Text("当前离线：保存后进入待同步队列").font(.system(size:9)).foregroundStyle(amber).padding(.bottom,8)
            Text("核对并保存成交记录").font(.system(size:13,weight:.semibold)).foregroundStyle(.white).frame(maxWidth:.infinity).frame(height:43).background(blue,in:RoundedRectangle(cornerRadius:12))
            Text("示例数据 · 账户与交易信息均为虚构").font(.system(size:9)).foregroundStyle(muted).frame(maxWidth:.infinity).padding(.top,8)
            Spacer().frame(height:30)
        }.padding(.horizontal,17).foregroundStyle(ink)
    }
}
struct AutoLiveCard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:11) {
            HStack(spacing:5) { PulseMark().scaleEffect(0.65).frame(width:19,height:18); Text("FFF 自动盯盘").font(.system(size:11,weight:.medium)); Spacer(); Text("10:18 更新").font(.system(size:9)).foregroundStyle(.white.opacity(0.6)) }
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:4) { Text("三星电子  005930").font(.system(size:12)); Text("208,000").font(.system(size:32,weight:.semibold,design:.rounded)).monospacedDigit() }
                Spacer(); Text("−10.34%").font(.system(size:16,weight:.semibold)).foregroundStyle(green).padding(.bottom,3)
            }
            HStack(spacing:5) { Image(systemName:"bell.badge"); Text("1项计划待确认"); Spacer(); Text("查看计划  ›").foregroundStyle(blue) }.font(.system(size:11)).foregroundStyle(amber)
            Rectangle().fill(.white.opacity(0.12)).frame(height:0.5)
            HStack { Text("银行 −1.09%"); Spacer(); Text("SK海力士 −12.33%") }.font(.system(size:9)).foregroundStyle(.white.opacity(0.65))
        }.foregroundStyle(.white).padding(15).background(Color(red:0.08,green:0.12,blue:0.18).opacity(0.94),in:RoundedRectangle(cornerRadius:21))
    }
}
struct AutoLockScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(colors:[Color(red:0.12,green:0.22,blue:0.36),Color(red:0.22,green:0.36,blue:0.53),Color(red:0.08,green:0.13,blue:0.22)],startPoint:.topLeading,endPoint:.bottomTrailing)
            VStack(spacing:0) {
                Capsule().fill(.black).frame(width:109,height:27).padding(.top,14)
                Image(systemName:"lock.fill").font(.system(size:15)).foregroundStyle(.white.opacity(0.8)).padding(.top,20)
                Text("10月16日 星期五").font(.system(size:16,weight:.medium)).foregroundStyle(.white.opacity(0.9)).padding(.top,8)
                Text("10:18").font(.system(size:80,weight:.thin,design:.rounded)).foregroundStyle(.white)
                AutoLiveCard().padding(.horizontal,12).padding(.top,47)
                Text("按市场自动出现 · 无需每天手动开始").font(.system(size:10)).foregroundStyle(.white.opacity(0.65)).padding(.top,12)
                Spacer()
                HStack { Image(systemName:"flashlight.off.fill"); Spacer(); Image(systemName:"camera.fill") }.font(.system(size:18)).foregroundStyle(.white.opacity(0.8)).padding(.horizontal,33).padding(.bottom,40)
            }
        }
    }
}
struct AutoIsland: View {
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("三星电子").font(.system(size:14,weight:.semibold)); Spacer(); Text("自动关注").font(.system(size:10)).foregroundStyle(.white.opacity(0.6)) }.padding(.top,7)
            HStack(alignment:.firstTextBaseline) { Text("208,000").font(.system(size:32,weight:.semibold,design:.rounded)); Spacer(); Text("−10.34%").font(.system(size:17,weight:.semibold)).foregroundStyle(green) }
            HStack(spacing:5) { Image(systemName:"bell.badge"); Text("1项价格条件到达 · 待确认") }.font(.system(size:11)).foregroundStyle(amber)
            HStack { Text("源时间 10:18").font(.system(size:9)).foregroundStyle(.white.opacity(0.5)); Spacer(); Text("查看计划  ›").font(.system(size:11)).foregroundStyle(blue) }
        }.foregroundStyle(.white).padding(20).background(.black,in:RoundedRectangle(cornerRadius:36))
    }
}
struct AutoWatchCard: View {
    var stale=false
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack { Text("三星电子").font(.system(size:13,weight:.semibold)); Spacer(); PulseMark().scaleEffect(0.5).frame(width:16,height:13) }
            Text("208,000").font(.system(size:27,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(stale ? .white.opacity(0.5) : .white)
            HStack { Text("−10.34%").font(.system(size:13,weight:.semibold)).foregroundStyle(stale ? .white.opacity(0.45) : green); Spacer(); Text(stale ? "10:08" : "10:18").font(.system(size:9)).foregroundStyle(.white.opacity(0.55)) }
            HStack(spacing:4) { Image(systemName:stale ? "clock" : "bell.badge"); Text(stale ? "待更新" : "1项计划待确认") }.font(.system(size:10)).foregroundStyle(amber)
        }.foregroundStyle(.white).padding(12).frame(width:190).background(Color(red:0.08,green:0.10,blue:0.14),in:RoundedRectangle(cornerRadius:21))
    }
}
struct AutoWatchDevice: View {
    var body: some View {
        VStack(spacing:-11) {
            RoundedRectangle(cornerRadius:22).fill(Color(red:0.18,green:0.21,blue:0.25)).frame(width:145,height:62)
            ZStack(alignment:.trailing) {
                VStack(spacing:14) {
                    HStack { Text("10:18"); Spacer(); Text("智能叠放") }.font(.system(size:10,weight:.medium)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal,19).padding(.top,17)
                    AutoWatchCard()
                    Capsule().fill(.white.opacity(0.16)).frame(width:135,height:23).overlay { Text("在手机查看计划").font(.system(size:9)).foregroundStyle(.white.opacity(0.45)) }
                    Spacer(minLength:8)
                }.frame(width:223,height:260).background(.black,in:RoundedRectangle(cornerRadius:43))
                Capsule().fill(Color(red:0.20,green:0.22,blue:0.25)).frame(width:8,height:32).offset(x:12,y:-59)
            }.padding(8).background(Color(red:0.24,green:0.27,blue:0.31),in:RoundedRectangle(cornerRadius:51)).overlay { RoundedRectangle(cornerRadius:51).stroke(.white.opacity(0.6),lineWidth:1) }.shadow(color:ink.opacity(0.14),radius:12,y:9)
            RoundedRectangle(cornerRadius:22).fill(Color(red:0.18,green:0.21,blue:0.25)).frame(width:145,height:77)
        }
    }
}
struct RuleRow: View {
    let title: String, detail: String, icon: String
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:icon).font(.system(size:14)).foregroundStyle(blue).frame(width:21)
            VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:13,weight:.semibold)).foregroundStyle(ink); Text(detail).font(.system(size:11)).foregroundStyle(muted).fixedSize(horizontal:false,vertical:true) }
        }
    }
}
struct WorkBoard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            Intro(title:"手机不是看板，是能办事的工作台。",subtitle:"计划 → 券商成交后手动记账 → 持仓与进度更新 → Mac 双向同步")
            HStack(alignment:.top,spacing:40) {
                VStack(spacing:18) { Phone { TodayScreen() }; Caption(title:"今日：该关注的自动出现",subtitle:"持仓、计划与待同步事项集中呈现。") }
                VStack(spacing:18) { Phone { PlansScreen() }; Caption(title:"计划：能看、能改、能跟进",subtitle:"条件、执行进度、记录入口，不再后置。") }
                VStack(spacing:18) { Phone { TradeRecordScreen() }; Caption(title:"记成交：随手记，安全同步",subtitle:"明确账户、实际价量、资金方式和关联计划。") }
            }
            Rectangle().fill(ink.opacity(0.1)).frame(height:1)
            Text("v2 概念预览 · 所有账户与数字为示意，非运行截图、非投资建议   |   保存记录不等于券商下单。")
                .font(.system(size:12)).foregroundStyle(muted)
        }.padding(47).frame(width:1280,height:1090,alignment:.topLeading).background(paper)
    }
}
struct AutoBoard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            Intro(title:"开盘即在场，不必每天再按开始。",subtitle:"一次授权 · 持仓、有效计划与置顶关注驱动 · 自动更新，不自动交易")
            HStack(alignment:.top,spacing:42) {
                VStack(spacing:18) { Phone { AutoLockScreen() }; Caption(title:"锁屏不只报价格，还提醒计划",subtitle:"默认隐藏账户、数量和收益等敏感信息。") }.frame(width:352)
                VStack(alignment:.leading,spacing:21) {
                    Caption(title:"默认自动，手动只留给例外",subtitle:"保留固定主标的与“今日暂停”，不强迫开场。")
                    HStack { PulseMark().scaleEffect(0.65).frame(width:18,height:18); Text("三星").font(.system(size:13)); Spacer().frame(width:68); Text("−10.34%").font(.system(size:14,weight:.semibold)).foregroundStyle(green) }.foregroundStyle(.white).padding(.horizontal,14).frame(height:47).background(.black,in:Capsule()).padding(.top,12)
                    AutoIsland().padding(.top,6)
                    RuleRow(title:"开盘自动恢复关注",detail:"按市场日历和持仓/计划规则发起活动。",icon:"sunrise").padding(.top,17)
                    RuleRow(title:"价格条件到达，才提醒",detail:"只提示待确认，不生成成交、不修改持仓。",icon:"bell.badge")
                    RuleRow(title:"记一笔成交，两端更新",detail:"实际成交确认后更新账本及计划进度。",icon:"square.and.pencil")
                    RuleRow(title:"收盘自动收尾",detail:"次日依规则恢复；今日暂停后不反复拉起。",icon:"moon")
                    Text("活动仍受系统时限、权限和推送预算约束；异常时显示“待更新”，不假装永久在线。")
                        .font(.system(size:11)).foregroundStyle(muted).lineSpacing(4).padding(.top,8)
                    Spacer()
                }.frame(width:354,height:810)
                VStack(alignment:.leading,spacing:20) {
                    Caption(title:"手表也能看到计划待办",subtitle:"与手机同一活动，不另建一套账本。")
                    AutoWatchDevice().frame(maxWidth:.infinity).padding(.top,25)
                    Text("离线/过期时如实提示").font(.system(size:13,weight:.semibold)).foregroundStyle(ink).padding(.top,19)
                    AutoWatchCard(stale:true).frame(maxWidth:.infinity)
                    Text("手表负责感知变化；\n记交易仍回到手机核对账户与真实成交。")
                        .font(.system(size:12)).foregroundStyle(muted).lineSpacing(5)
                    Spacer()
                }.frame(width:264,height:810)
            }
            Rectangle().fill(ink.opacity(0.1)).frame(height:1)
            Text("v2 概念预览 · 非运行截图   |   自动发起与后台更新按 APNs / 有效权限和令牌规划；不承诺绕过系统限制。")
                .font(.system(size:12)).foregroundStyle(muted)
        }.padding(47).frame(width:1280,height:1110,alignment:.topLeading).background(paper)
    }
}
@main struct RenderWorkDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/fff-iphone-v2",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try render(WorkBoard(),to:folder.appendingPathComponent("01-daily-workbench.png"))
        try render(AutoBoard(),to:folder.appendingPathComponent("02-automatic-live-watch.png"))
    }
    @MainActor static func render<V:View>(_ view:V,to url:URL) throws {
        let renderer=ImageRenderer(content:view.environment(\.colorScheme,.light)); renderer.scale=2
        guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"DesignRender",code:1) }
        try png.write(to:url); print("已生成：\(url.path)")
    }
}
