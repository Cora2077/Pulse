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
struct Tabs: View {
    let selected: Int
    let items = [("star.fill", "自选"), ("waveform.path.ecg", "盯盘"), ("person.crop.circle", "我的")]
    var body: some View {
        HStack {
            ForEach(0..<3) { index in
                VStack(spacing: 4) {
                    Image(systemName: items[index].0).font(.system(size: 18, weight: .medium))
                    Text(items[index].1).font(.system(size: 10, weight: .medium))
                }.foregroundStyle(index == selected ? blue : muted).frame(maxWidth: .infinity)
            }
        }.frame(height: 51).padding(.top, 6).background(Color.white)
            .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.07)).frame(height: 0.5) }
    }
}
struct Status: View {
    var body: some View {
        HStack {
            Text("9:41").font(.system(size: 12, weight: .semibold))
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
struct WatchlistScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            Status()
            HStack(spacing: 8) {
                PulseMark(); Text("FFF").font(.system(size: 25, weight: .bold))
                Spacer(); Image(systemName: "plus").font(.system(size: 19, weight: .medium)).foregroundStyle(blue)
            }.foregroundStyle(ink).padding(.top, 16)
            HStack { Text("自选").font(.system(size: 27, weight: .bold)); Spacer(); Text("编辑").font(.system(size: 12)).foregroundStyle(blue) }.padding(.top, 19)
            HStack(spacing: 5) {
                ForEach(["持仓", "指数", "跟踪", "美股", "行业"], id: \.self) { item in
                    Text(item).font(.system(size: 12, weight: item == "跟踪" ? .semibold : .regular))
                        .foregroundStyle(item == "跟踪" ? blue : muted)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(item == "跟踪" ? blue.opacity(0.09) : .clear, in: Capsule())
                }
                Spacer(minLength: 0)
            }.padding(.top, 10)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass"); Text("搜索中文名称或代码"); Spacer() }
                .font(.system(size: 12)).foregroundStyle(muted).padding(11)
                .background(paper, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 12).padding(.bottom, 8)
            VStack(spacing: 0) {
                StockRow(name: "银行", code: "881155", market: "行业", price: "1,386.064", change: "−1.09%")
                Divider().opacity(0.45)
                StockRow(name: "三星电子", code: "005930", market: "韩", price: "208,000", change: "−10.34%")
                Divider().opacity(0.45)
                StockRow(name: "SK海力士", code: "000660", market: "韩", price: "1,244,000", change: "−12.33%")
                Divider().opacity(0.45)
                StockRow(name: "韩国综合指数", code: "KOSPI", market: "韩", price: "5,554.22", change: "−7.57%")
                Divider().opacity(0.45)
                StockRow(name: "苹果", code: "AAPL", market: "美", price: "237.81", change: "+0.86%", up: true)
            }
            Spacer(minLength: 7)
            HStack(spacing: 5) { Circle().fill(blue).frame(width: 4, height: 4); Text("更新于 09:41"); Spacer(); Text("示意数据") }
                .font(.system(size: 9)).foregroundStyle(muted).padding(.bottom, 13)
            Tabs(selected: 0).padding(.horizontal, -17)
            Spacer().frame(height: 25)
        }.padding(.horizontal, 17).foregroundStyle(ink)
    }
}
struct Candles: View {
    var body: some View {
        Canvas { context, size in
            for i in 0..<5 {
                let y = CGFloat(i) * size.height / 4
                var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(muted.opacity(0.11)), lineWidth: 0.6)
            }
            let n = 35
            for i in 0..<n {
                let x = (CGFloat(i)+0.5)*size.width/CGFloat(n)
                let base = 0.68 - Double(i) * 0.011 + 0.13*sin(Double(i)*0.49)
                let delta = 0.07*sin(Double(i)*1.7)
                let y1 = CGFloat(base)*size.height, y2 = CGFloat(base+delta)*size.height
                let c = delta < 0 ? red : green
                var wick = Path(); wick.move(to: CGPoint(x:x,y:min(y1,y2)-7)); wick.addLine(to:CGPoint(x:x,y:max(y1,y2)+8))
                context.stroke(wick, with: .color(c), lineWidth: 0.9)
                context.fill(Path(CGRect(x:x-2.3,y:min(y1,y2),width:4.6,height:max(1.4,abs(y1-y2)))), with:.color(c))
                let v = 0.03+0.07*abs(sin(Double(i)*1.8))
                context.fill(Path(CGRect(x:x-2.3,y:size.height-CGFloat(v)*size.height,width:4.6,height:CGFloat(v)*size.height)), with:.color(c.opacity(0.3)))
            }
        }.frame(height: 199)
    }
}
struct DetailScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Status().padding(.horizontal, -17)
            HStack { Label("自选", systemImage: "chevron.left").foregroundStyle(blue); Spacer(); Image(systemName: "star.fill").foregroundStyle(blue); Image(systemName: "ellipsis").padding(.leading, 12) }
                .font(.system(size: 13)).padding(.top, 19)
            Text("银行").font(.system(size: 27, weight: .bold)).padding(.top, 21)
            HStack(spacing: 6) { Tag(text:"行业"); Text("881155 · 同花顺").font(.system(size: 11)).foregroundStyle(muted) }.padding(.top, 4)
            Text("1,386.064").font(.system(size: 39, weight: .semibold, design: .rounded)).monospacedDigit().padding(.top, 16)
            Text("−15.217   −1.09%").font(.system(size: 14, weight: .medium)).foregroundStyle(green).padding(.top, 3)
            Text("源时间 09:41 · 示意数据").font(.system(size: 10)).foregroundStyle(muted).padding(.top, 8)
            HStack {
                ForEach(["分时", "分钟", "日K", "周K", "月K"], id: \.self) { label in
                    Text(label).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(label == "日K" ? blue : muted)
                        .background(label == "日K" ? blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
            }.padding(.top, 18)
            Candles().padding(.top, 15)
            HStack { Text("08/01"); Spacer(); Text("09/01"); Spacer(); Text("10/15") }.font(.system(size: 9)).foregroundStyle(muted).padding(.top, 5)
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("今开"); Text("1,399.054").foregroundStyle(ink) }
                Spacer()
                VStack(alignment: .leading, spacing: 5) { Text("最高"); Text("1,399.054").foregroundStyle(ink) }
                Spacer()
                VStack(alignment: .leading, spacing: 5) { Text("最低"); Text("1,372.647").foregroundStyle(ink) }
            }.font(.system(size: 10)).foregroundStyle(muted).padding(.top, 20)
            Spacer(minLength: 10)
            HStack { Image(systemName:"waveform.path.ecg"); Text("加入本场盯盘").fontWeight(.semibold) }.font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(.white).background(blue,in:RoundedRectangle(cornerRadius: 13))
            Text("让灵动岛和手表显示这只指数").font(.system(size: 10)).foregroundStyle(muted).frame(maxWidth: .infinity).padding(.top, 8)
            Spacer().frame(height: 34)
        }.padding(.horizontal, 17).foregroundStyle(ink)
    }
}
struct SettingRow: View {
    let title: String, value: String
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(muted); Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(muted.opacity(0.7)) }
            .font(.system(size:12)).frame(height: 40)
    }
}
struct ToggleRow: View {
    let title: String
    var on = true
    var body: some View {
        HStack { Text(title).font(.system(size:12)); Spacer()
            Capsule().fill(on ? blue : muted.opacity(0.25)).frame(width:33,height:20)
                .overlay(alignment:on ? .trailing : .leading) { Circle().fill(.white).frame(width:16,height:16).padding(2) }
        }.frame(height:38)
    }
}
struct FocusScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Status().padding(.horizontal,-17)
            Text("本场盯盘").font(.system(size:27,weight:.bold)).padding(.top,20)
            Text("手机 · 锁屏 · Apple Watch").font(.system(size:11)).foregroundStyle(muted).padding(.top,5)
            VStack(alignment:.leading,spacing:6) {
                Text("主标的").font(.system(size:10)).foregroundStyle(muted)
                HStack { Text("银行").font(.system(size:19,weight:.semibold)); Spacer(); Text("881155").font(.system(size:11,design:.monospaced)).foregroundStyle(muted); Image(systemName:"chevron.right").font(.system(size:11)).foregroundStyle(muted) }
            }.padding(14).background(paper,in:RoundedRectangle(cornerRadius:13)).padding(.top,19)
            Text("辅助标的 · 锁屏展开时可见").font(.system(size:10)).foregroundStyle(muted).padding(.top,17)
            ForEach(["三星电子", "SK海力士"], id:\.self) { name in
                HStack { Text(name).font(.system(size:13)); Spacer(); Image(systemName:"checkmark.circle.fill").foregroundStyle(blue) }.frame(height:34)
            }
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:6) { Circle().fill(blue).frame(width:5,height:5); Text("后台行情服务已连接").font(.system(size:12,weight:.medium)) }
                Text("推送版目标示意 · 实际频率由系统决定").font(.system(size:9)).foregroundStyle(muted)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(blue.opacity(0.055),in:RoundedRectangle(cornerRadius:10)).padding(.top,11)
            VStack(spacing:0) {
                SettingRow(title:"结束条件", value:"本场收盘")
                Divider().opacity(0.45)
                SettingRow(title:"更新策略", value:"标准 · 1分钟目标")
                Divider().opacity(0.45)
                ToggleRow(title:"自动同步到手表")
                Divider().opacity(0.45)
                ToggleRow(title:"数据过期时醒目标记")
                Divider().opacity(0.45)
                ToggleRow(title:"锁屏显示持仓收益", on:false)
            }.padding(.top,10)
            Spacer(minLength:8)
            Text("不保证逐秒刷新；旧数据必须显示源时间。").font(.system(size:9)).foregroundStyle(muted).padding(.bottom,9)
            Text("开始本场盯盘").font(.system(size:14,weight:.semibold)).frame(maxWidth:.infinity).frame(height:44).foregroundStyle(.white).background(blue,in:RoundedRectangle(cornerRadius:13)).padding(.bottom,14)
            Tabs(selected:1).padding(.horizontal,-17)
            Spacer().frame(height:25)
        }.padding(.horizontal,17).foregroundStyle(ink)
    }
}
struct LiveCard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:6) { PulseMark().scaleEffect(0.65).frame(width:19,height:18); Text("FFF 盯盘").font(.system(size:11,weight:.medium)); Spacer(); Text("更新于 09:41").font(.system(size:9)).foregroundStyle(.white.opacity(0.65)) }
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:3) { Text("银行  881155").font(.system(size:12)); Text("1,386.064").font(.system(size:29,weight:.semibold,design:.rounded)).monospacedDigit() }
                Spacer(); Text("−1.09%").font(.system(size:18,weight:.semibold)).foregroundStyle(green).padding(.bottom,2)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height:0.5)
            HStack { Text("三星电子"); Spacer(); Text("−10.34%").foregroundStyle(green); Rectangle().fill(.white.opacity(0.14)).frame(width:0.5,height:12); Text("SK海力士"); Spacer(); Text("−12.33%").foregroundStyle(green) }.font(.system(size:10))
        }.foregroundStyle(.white).padding(15).background(Color(red:0.08,green:0.12,blue:0.18).opacity(0.92),in:RoundedRectangle(cornerRadius:21))
    }
}
struct LockScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(colors:[Color(red:0.12,green:0.22,blue:0.36),Color(red:0.22,green:0.36,blue:0.53),Color(red:0.08,green:0.13,blue:0.22)],startPoint:.topLeading,endPoint:.bottomTrailing)
            Circle().fill(Color.blue.opacity(0.15)).frame(width:350,height:350).blur(radius:55).offset(x:150,y:100)
            VStack(spacing:0) {
                Capsule().fill(.black).frame(width:109,height:27).padding(.top,14)
                Image(systemName:"lock.fill").font(.system(size:15)).foregroundStyle(.white.opacity(0.8)).padding(.top,20)
                Text("10月15日 星期四").font(.system(size:16,weight:.medium)).foregroundStyle(.white.opacity(0.9)).padding(.top,8)
                Text("09:41").font(.system(size:80,weight:.thin,design:.rounded)).foregroundStyle(.white)
                LiveCard().padding(.horizontal,12).padding(.top,49)
                Text("本场关注 · 点按卡片查看详情").font(.system(size:10)).foregroundStyle(.white.opacity(0.65)).padding(.top,12)
                Spacer()
                HStack { Image(systemName:"flashlight.off.fill"); Spacer(); Image(systemName:"camera.fill") }.font(.system(size:18)).foregroundStyle(.white.opacity(0.8)).padding(.horizontal,33).padding(.bottom,40)
            }
        }
    }
}
struct CompactIsland: View {
    var body: some View {
        HStack {
            HStack(spacing:4) { PulseMark().scaleEffect(0.65).frame(width:18,height:18); Text("银").font(.system(size:14,weight:.medium)) }
            Spacer().frame(width:92)
            Text("−1.09%").font(.system(size:15,weight:.semibold)).foregroundStyle(green)
        }.foregroundStyle(.white).padding(.horizontal,16).frame(height:48).background(.black,in:Capsule())
    }
}
struct ExpandedIsland: View {
    var stale = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("银行").font(.system(size:14,weight:.semibold)); Spacer(); Text(stale ? "待更新" : "FFF 盯盘").font(.system(size:10)).foregroundStyle(stale ? amber : .white.opacity(0.65)) }.padding(.top,8)
            HStack(alignment:.firstTextBaseline) {
                Text("1,386.064").font(.system(size:31,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(stale ? .white.opacity(0.6) : .white)
                Spacer(); Text("−1.09%").font(.system(size:17,weight:.semibold)).foregroundStyle(stale ? .white.opacity(0.5) : green)
            }
            HStack { Text(stale ? "源时间 09:38 · 行情可能已过期" : "三星电子 −10.34%    SK海力士 −12.33%").font(.system(size:10)).foregroundStyle(stale ? amber : .white.opacity(0.75)); Spacer() }
            HStack { PulseMark().scaleEffect(0.55).frame(width:18,height:16); Text(stale ? "09:38" : "09:41 更新").font(.system(size:9)).foregroundStyle(.white.opacity(0.55)); Spacer(); Text("打开详情  ›").font(.system(size:11)).foregroundStyle(blue) }
        }.padding(20).foregroundStyle(.white).background(.black,in:RoundedRectangle(cornerRadius:37))
    }
}
struct WatchCard: View {
    var stale = false
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:5) { PulseMark().scaleEffect(0.5).frame(width:17,height:14); Text("银行").font(.system(size:14,weight:.semibold)); Spacer(); if stale { Text("待更新").font(.system(size:9)).foregroundStyle(amber) } }
            Text("881155").font(.system(size:9,design:.monospaced)).foregroundStyle(.white.opacity(0.5))
            Text("1,386.06").font(.system(size:27,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(stale ? .white.opacity(0.5) : .white)
            HStack { Text("−1.09%").font(.system(size:14,weight:.semibold)).foregroundStyle(stale ? .white.opacity(0.45) : green); Spacer(); Text(stale ? "09:38" : "09:41 更新").font(.system(size:9)).foregroundStyle(.white.opacity(0.55)) }
        }.padding(12).frame(width:190).background(Color(red:0.08,green:0.10,blue:0.14),in:RoundedRectangle(cornerRadius:21)).foregroundStyle(.white)
    }
}
struct WatchDevice: View {
    var body: some View {
        VStack(spacing:-11) {
            RoundedRectangle(cornerRadius:22).fill(Color(red:0.18,green:0.21,blue:0.25)).frame(width:145,height:62)
            ZStack(alignment:.trailing) {
                VStack(spacing:14) {
                    HStack { Text("09:41"); Spacer(); Text("智能叠放") }.font(.system(size:10,weight:.medium)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal,19).padding(.top,17)
                    WatchCard()
                    Capsule().fill(.white.opacity(0.16)).frame(width:135,height:25).overlay { Text("下一张卡片").font(.system(size:9)).foregroundStyle(.white.opacity(0.4)) }
                    Spacer(minLength:10)
                }.frame(width:223,height:260).background(.black,in:RoundedRectangle(cornerRadius:43))
                Capsule().fill(Color(red:0.20,green:0.22,blue:0.25)).frame(width:8,height:32).offset(x:12,y:-59)
            }.padding(8).background(Color(red:0.24,green:0.27,blue:0.31),in:RoundedRectangle(cornerRadius:51)).overlay { RoundedRectangle(cornerRadius:51).stroke(.white.opacity(0.6),lineWidth:1) }.shadow(color:ink.opacity(0.14),radius:12,y:9)
            RoundedRectangle(cornerRadius:22).fill(Color(red:0.18,green:0.21,blue:0.25)).frame(width:145,height:77)
        }
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
struct LiveBoard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            Intro(title:"不解锁，也能盯住关键变化。",subtitle:"灵动岛 · 锁屏实时活动 · Apple Watch 智能叠放")
            HStack(alignment:.top,spacing:42) {
                VStack(spacing:18) { Phone { LockScreen() }; Caption(title:"锁屏，抬眼就能看",subtitle:"一只主标的 + 两只辅助关注，明确源时间。") }.frame(width:352)
                VStack(alignment:.leading,spacing:20) {
                    Caption(title:"灵动岛，只保留重点",subtitle:"收起看涨跌，长按看价格与本场关注。")
                    CompactIsland().fixedSize(horizontal:true,vertical:false).frame(maxWidth:.infinity).padding(.top,17)
                    Text("收起：主标的 + 涨跌幅").font(.system(size:11)).foregroundStyle(muted).frame(maxWidth:.infinity)
                    HStack(spacing:12) {
                        HStack(spacing:3) { PulseMark().scaleEffect(0.6).frame(width:18,height:17); Image(systemName:"arrow.down").font(.system(size:10,weight:.semibold)).foregroundStyle(green) }.padding(9).background(.black,in:Capsule())
                        Text("最小态：多个活动共存时仍可辨认").font(.system(size:10)).foregroundStyle(muted)
                    }.frame(maxWidth:.infinity)
                    ExpandedIsland().padding(.top,4)
                    Text("展开：价格、辅助标的、更新时间").font(.system(size:11)).foregroundStyle(muted)
                    ExpandedIsland(stale:true).padding(.top,17)
                    HStack(alignment:.top,spacing:8) { Image(systemName:"clock.badge.exclamationmark").foregroundStyle(amber); Text("过期就说过期。\n不让旧行情伪装成实时更新。").font(.system(size:13)).foregroundStyle(muted).lineSpacing(5) }.padding(.top,6)
                    Spacer()
                }.frame(width:354,height:810)
                VStack(alignment:.leading,spacing:20) {
                    Caption(title:"抬腕，延续同一场盯盘",subtitle:"镜像到手表，不另开一套行情。")
                    WatchDevice().frame(maxWidth:.infinity).padding(.top,27)
                    Text("小卡专用布局").font(.system(size:13,weight:.semibold)).foregroundStyle(ink).padding(.top,19)
                    WatchCard(stale:true).frame(maxWidth:.infinity)
                    Text("只显示主标的。\n缺少新数据时保留源时间，标记待更新。")
                        .font(.system(size:12)).foregroundStyle(muted).lineSpacing(5)
                    Spacer()
                }.frame(width:264,height:810)
            }
            Rectangle().fill(ink.opacity(0.10)).frame(height:1)
            Text("设计预览 · 全部为示意数据 · 非运行截图   |   持续后台更新需推送权限与更新服务；实际显示和频率由系统决定。")
                .font(.system(size:12)).foregroundStyle(muted)
        }.padding(47).frame(width:1280,height:1110,alignment:.topLeading).background(paper)
    }
}
struct AppBoard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:28) {
            Intro(title:"把操作留在 App，把变化留在眼前。",subtitle:"自选 → 标的详情 → 开启本场盯盘；不把桌面窗口缩小塞进手机。")
            HStack(alignment:.top,spacing:40) {
                VStack(spacing:18) { Phone { WatchlistScreen() }; Caption(title:"自选与中文搜索",subtitle:"复用现有分组与代码，韩股名称显示中文。") }
                VStack(spacing:18) { Phone { DetailScreen() }; Caption(title:"图表与盯盘入口",subtitle:"真实源时间、当日日线、触控图表。") }
                VStack(spacing:18) { Phone { FocusScreen() }; Caption(title:"本场盯盘设置",subtitle:"主次标的、结束条件、过期提示及手表同步。") }
            }
            Rectangle().fill(ink.opacity(0.10)).frame(height:1)
            Text("设计预览 · 全部为示意数据 · 非运行截图   |   右侧展示推送版目标状态，不代表免费签名已具备后台推送能力。")
                .font(.system(size:12)).foregroundStyle(muted)
        }.padding(47).frame(width:1280,height:1090,alignment:.topLeading).background(paper)
    }
}
@main struct RenderDesign {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "/tmp/fff-iphone-previews",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try render(LiveBoard(), to:folder.appendingPathComponent("01-live-activities-watch.png"))
        try render(AppBoard(), to:folder.appendingPathComponent("02-iphone-app.png"))
    }
    @MainActor static func render<V:View>(_ view:V,to url:URL) throws {
        let renderer = ImageRenderer(content:view.environment(\.colorScheme,.light))
        renderer.scale = 2
        guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"DesignRender",code:1) }
        try png.write(to:url)
        print("已生成：\(url.path)")
    }
}
