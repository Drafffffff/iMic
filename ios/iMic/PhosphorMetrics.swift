import Foundation

/// Completion handlers sample GPU time without touching UI state or starting work.
/// The same window also reports main-thread frame building (CPU) for the display clock.
final class PhosphorMetrics: @unchecked Sendable {
    private let lock=NSLock()
    private var times=[Double](repeating:0,count:240)
    private var count=0
    private let label:String

    init(label:String="HDR GPU"){self.label=label}

    func record(start:Double,end:Double){
        guard start>0,end>start else{return}
        lock.lock();defer{lock.unlock()}
        count+=1
        guard count>12 else{return}
        let i=(count-13)%times.count
        times[i]=(end-start)*1000
        if i==times.count-1 {
            let sorted=times.sorted()
            let mean=times.reduce(0,+)/Double(times.count)
            IMicLog.write("iphone.visual",String(format:"%@ mean=%.2fms p95=%.2fms max=%.2fms",label,mean,sorted[228],sorted.last!))
        }
    }
}
