//
//  BannerAdView.swift
//  PointMe
//
//  Created by 永井涼 on 2025/05/25.
//

import SwiftUI
import GoogleMobileAds

struct BannerAdView: UIViewRepresentable {
    var bannerID: String {
    #if DEBUG
    return "ca-app-pub-3940256099942544/2934735716"// テスト広告ID
    #else
    return "ca-app-pub-1909140510546146/3012390695"
    #endif
    }
    
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
           banner.adUnitID = bannerID
           banner.rootViewController = UIApplication.shared
               .connectedScenes
               .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
               .first
        banner.load(Request())
           return banner
       }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
