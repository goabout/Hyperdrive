//
//  Hyperdrive.swift
//  Hyperdrive
//
//  Created by Kyle Fuller on 08/04/2015.
//  Copyright (c) 2015 Apiary. All rights reserved.
//

import Foundation
import Representor
import URITemplate
import Result

/// Map a dictionaries values
func map<K,V>(_ source:[K:V], transform:((V) -> V)) -> [K:V] {
  var result = [K:V]()
  
  for (key, value) in source {
    result[key] = transform(value)
  }
  
  return result
}

/// Returns an absolute URI for a URI given a base URL
func absoluteURI(_ baseURL:URL?, _ uri:String) -> String {
  return URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
}

/// Traverses a representor and ensures that all URIs are absolute given a base URL
func absoluteRepresentor(_ baseURL:URL?, _ original:Representor<HTTPTransition>) -> Representor<HTTPTransition> {
  
  

  let transitions = map(original.transitions) { transitions in
    return transitions.map { transition in
      return HTTPTransition(uri: absoluteURI(baseURL, transition.uri), { (builder: HTTPTransition.Builder) in
        builder.method = transition.method
        builder.suggestedContentTypes = transition.suggestedContentTypes
        
        for (name, attribute) in transition.attributes {
          builder.addAttribute(name, value: attribute.value, defaultValue: attribute.defaultValue)
        }
        
        for (name, parameter) in transition.parameters {
          builder.addParameter(name, value: parameter.value, defaultValue: parameter.defaultValue)
        }
      })
    }
  }
  
  let representors = map(original.representors) { representors in
    representors.map({ representor  in
        absoluteRepresentor(baseURL, representor)
    })
  }
  
  return Representor(transitions: transitions, representors: representors, attributes: original.attributes, metadata: original.metadata)
}


public typealias RepresentorResult = Result<Representor<HTTPTransition>, NSError>
public typealias RequestResult = Result<URLRequest, NSError>
public typealias ResponseResult = Result<HTTPURLResponse, NSError>


/// A hypermedia API client
open class Hyperdrive {
  open static var errorDomain:String {
    return "Hyperdrive"
  }
  
  fileprivate var session: URLSession
  
  /// An array of the supported content types in order of preference
  let preferredContentTypes:[String]
  
  /** Initialize hyperdrive
   - parameter preferredContentTypes: An optional array of the supported content types in order of preference, when this is nil. All types supported by the Representor will be used.
   - parameter sessionConfiguration: An optional session configuration. Can be useful to adding custom session-level headers or for configure session as background.
   */
  public init(preferredContentTypes:[String]? = nil, sessionConfiguration: URLSessionConfiguration? = nil) {
    let configuration = sessionConfiguration ?? URLSessionConfiguration.default
    session = URLSession(configuration: configuration)
    self.preferredContentTypes = preferredContentTypes ?? HTTPDeserialization.preferredContentTypes
  }
  
  
  /** Creating new session with specified configuration and sets as default for this Hyperdrive instance.
   - parameter configuration: Session configuration. Can contains custom session-level headers or setup session as background.
   */
  open func setSessionConfiguration(_ configuration: URLSessionConfiguration) {
    session = URLSession(configuration: configuration)
  }
  
  // MARK: -
  
  /// Enter a hypermedia API given the root URI
  open func enter(_ uri:String, completion:@escaping ((RepresentorResult) -> Void)) {
    request(uri, completion:completion)
  }
  
  // MARK: Subclass hooks
  
  /// Construct a request from a URI and parameters
  open func constructRequest(_ uri:String, parameters:[String:Any]? = nil) -> RequestResult {
    let expandedURI = URITemplate(template: uri).expand(parameters ?? [:])
    print(expandedURI)
    let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Creating URL from given URI failed"])
    return Result(URL(string: expandedURI), failWith: error).map { URL in
      var request = URLRequest(url: URL)
      request.setValue(preferredContentTypes.joined(separator: ", "), forHTTPHeaderField: "Accept")
      return request
    }
  }
  
  open func constructRequest(_ transition:HTTPTransition, parameters:[String:Any]?  = nil, attributes:[String:Any]? = nil, method: String? = nil) -> RequestResult {
    return constructRequest(transition.uri, parameters:parameters).map { request in
      var request = request
      
      request.httpMethod = method ?? transition.method
      
      if (request.httpMethod == "POST" || request.httpMethod == "PUT") {
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      
      if let attributes = attributes {
        request.httpBody = self.encodeAttributes(attributes, suggestedContentTypes: transition.suggestedContentTypes)
      }
      
      return request
    }
  }
  
  func encodeAttributes(_ attributes:[String:Any], suggestedContentTypes:[String]) -> Data? {
    let JSONEncoder = { (attributes:[String:Any]) -> Data? in
      return try? JSONSerialization.data(withJSONObject: attributes, options: JSONSerialization.WritingOptions(rawValue: 0))
    }
    
    let encoders:[String:(([String:Any]) -> Data?)] = [
      "application/json": JSONEncoder
    ]
    
    for contentType in suggestedContentTypes {
      if let encoder = encoders[contentType] {
        return encoder(attributes)
      }
    }
    
    return JSONEncoder(attributes)
  }
  
  open func constructResponse(_ request:URLRequest, response:HTTPURLResponse, body:Data?) -> Representor<HTTPTransition>? {
    if let body = body {
      let representor = HTTPDeserialization.deserialize(response, body: body)
      if let representor = representor {
        return absoluteRepresentor(response.url, representor)
      }
    }
    
    return nil
  }
  
  // MARK: Perform requests
  
  func request(_ request:URLRequest, completion:@escaping ((RepresentorResult) -> Void)) {
    let dataTask = session.dataTask(with: request, completionHandler: { (body, response, error) -> Void in
      if let error = error {
        DispatchQueue.main.async {
          completion(RepresentorResult.failure(error as NSError))
        }
      } else {
        let representor = self.constructResponse(request, response:response as! HTTPURLResponse, body: body) ?? Representor<HTTPTransition>()
        DispatchQueue.main.async {
          completion(.success(representor))
        }
      }
    })
    
    dataTask.resume()
  }
  
  /// Perform a request with a given URI and parameters
  open func request(_ uri:String, parameters:[String:Any]? = nil, completion:@escaping ((RepresentorResult) -> Void)) {
    switch constructRequest(uri, parameters: parameters) {
    case .success(let request):
      self.request(request, completion:completion)
    case .failure(let error):
      completion(.failure(error))
    }
  }
  
  /// Perform a transition with a given parameters and attributes
  open func request(_ transition:HTTPTransition, parameters:[String:Any]? = nil, attributes:[String:Any]? = nil, method:String? = nil, completion:@escaping ((RepresentorResult) -> Void)) {
    let result = constructRequest(transition, parameters: parameters, attributes: attributes, method: method)
    
    switch result {
    case .success(let request):
      self.request(request, completion:completion)
    case .failure(let error):
      completion(.failure(error))
    }
  }
}
