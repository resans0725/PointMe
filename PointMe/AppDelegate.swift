//
//  AppDelegate.swift
//  PointMe
//
//  Created by 永井涼 on 2025/05/25.
//

import SwiftUI
import FirebaseCore
import Firebase
import GoogleMobileAds


class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    FirebaseApp.configure()
      
      MobileAds.shared.start(completionHandler: nil)
      
      // 起動時にイベントをログ
      Analytics.logEvent("app_launch", parameters: [
          "timestamp": Date().timeIntervalSince1970
      ])

    return true
  }
}

