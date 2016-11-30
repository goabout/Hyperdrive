//
//  Extensions.swift
//  Hyperdrive
//
//  Created by Artem Golovin on 10/04/16.
//  Copyright © 2016 Apiary. All rights reserved.
//

import Foundation


extension Dictionary {
  init(_ pairs: [Element]) {
    self.init()
    for (k, v) in pairs {
      self[k] = v
    }
  }
  
  func mapPairs<OutKey: Hashable, OutValue>(_ transform: (Element) throws -> (OutKey, OutValue)) rethrows -> [OutKey: OutValue] {
    return Dictionary<OutKey, OutValue>(try map(transform))
  }
  
  func filterPairs(_ includeElement: (Element) throws -> Bool) rethrows -> [Key: Value] {
    return Dictionary(try filter(includeElement))
  }
}
