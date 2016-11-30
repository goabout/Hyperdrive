//
//  HyperBlueprint.swift
//  Hyperdrive
//
//  Created by Kyle Fuller on 12/04/2015.
//  Copyright (c) 2015 Apiary. All rights reserved.
//

import Foundation
import Representor
import URITemplate
import WebLinking
import Result


func absoluteURITemplate(_ baseURL:String, uriTemplate:String) -> String {
  switch (baseURL.hasSuffix("/"), uriTemplate.hasPrefix("/")) {
  case (true, true):
    return baseURL.substring(to: baseURL.characters.index(before: baseURL.endIndex)) + uriTemplate
  case (true, false):
    fallthrough
  case (false, true):
    return baseURL + uriTemplate
  case (false, false):
    return baseURL + "/" + uriTemplate
  }
}

private func uriForAction(_ resource:Resource, action:Action) -> String {
  var uriTemplate = resource.uriTemplate

  // Empty action uriTemplate == no template
  if let uri = action.uriTemplate {
    if !uri.isEmpty {
      uriTemplate = uri
    }
  }

  return uriTemplate
}

private func decodeJSON(_ data:Data) -> Result<Any, NSError> {
  return Result(try JSONSerialization.jsonObject(with: data as Data, options: JSONSerialization.ReadingOptions(rawValue: 0)))
}

private func decodeJSON<T>(_ data:Data) -> Result<T, NSError> {
  return Result(try JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions(rawValue: 0))).flatMap {
    if let value = $0 as? T {
      return .success(value)
    }

    let invaidJSONError = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Returned JSON object was not of expected type."])
    return .failure(invaidJSONError)
  }
}

extension Resource {
  var dataStructure:[String:Any]? {
    return content.filter {
      element in (element["element"] as? String) == "dataStructure"
    }.first
  }

  var typeDefinition:[String:Any]? {
    return dataStructure?["typeDefinition"] as? [String:Any]
  }

  var typeSpecification:[String:Any]? {
    return typeDefinition?["typeSpecification"] as? [String:Any]
  }

  func actionForMethod(_ method:String) -> Action? {
    return actions.filter { action in
      return action.method == method
    }.first
  }
}


public typealias HyperBlueprintResultSuccess = (Hyperdrive, Representor<HTTPTransition>)
public typealias HyperBlueprintResult = Result<HyperBlueprintResultSuccess, NSError>

/// A subclass of Hyperdrive which supports requests from an API Blueprint
open class HyperBlueprint : Hyperdrive {
  let baseURL:URL
  let blueprint:Blueprint

  // MARK: Entering an API

  /// Enter an API from a blueprint hosted on Apiary using the given domain
  open class func enter(apiary: String, baseURL:URL? = nil, completion: @escaping ((HyperBlueprintResult) -> Void)) {
    let url = "https://jsapi.apiary.io/apis/\(apiary).apib"
    self.enter(blueprintURL: url, baseURL: baseURL, completion: completion)
  }

  /// Enter an API from a blueprint URI
  open class func enter(blueprintURL: String, baseURL:URL? = nil, completion: @escaping ((HyperBlueprintResult) -> Void)) {
    if let URL = URL(string: blueprintURL) {
      var request = URLRequest(url: URL)
      request.setValue("text/vnd.apiblueprint+markdown; version=1A", forHTTPHeaderField: "Accept")
      let session = URLSession(configuration: URLSessionConfiguration.default)
      session.dataTask(with: request, completionHandler: { (body, response, error) in
        if let error = error {
          DispatchQueue.main.async {
            completion(.failure(error as NSError))
          }
        } else if let body = body {
            self.enter(blueprint: body, baseURL: baseURL, completion: completion)
        } else {
          let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Response has no body."])
          DispatchQueue.main.async {
            completion(.failure(error))
          }
        }
        }) .resume()
    } else {
      let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URI for blueprint \(blueprintURL)"])
      completion(.failure(error))
    }
  }

  class func enter(blueprint: Data, baseURL:URL? = nil, completion: @escaping ((HyperBlueprintResult) -> Void)) {
    let parserURL = URL(string: "https://api.apiblueprint.org/parser")!
    var request = URLRequest(url: parserURL)
    request.httpMethod = "POST"
    request.httpBody = blueprint
    request.setValue("text/vnd.apiblueprint+markdown; version=1A", forHTTPHeaderField: "Content-Type")
    request.setValue("application/vnd.apiblueprint.parseresult+json; version=2.1", forHTTPHeaderField: "Accept")

    let session = URLSession(configuration: URLSessionConfiguration.default)
    
    session.dataTask(with: request, completionHandler: { (body, response, error) in
      if let error = error {
        DispatchQueue.main.async {
          completion(.failure(error as NSError))
        }
      } else if let body = body {
        switch decodeJSON(body) {
        case .success(let parseResult):
          
          if let dict = parseResult as? [String : Any], let ast = dict["ast"] as? [String:Any] {
            let blueprint = Blueprint(ast: ast)
            self.enter(blueprint, baseURL: baseURL, completion: completion)
          } else {
            DispatchQueue.main.async {
              completion(.failure(error as? NSError ?? NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Server returned invalid API Blueprint AST."])))
            }
          }
        case .failure(let error):
          DispatchQueue.main.async {
            
            completion(.failure(error as NSError /*?? NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Server returned invalid API Blueprint AST."])*/))
          }
        }
      } else {
        let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Response has no body."])
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }) .resume()
  }

  /// Enter an API with a blueprint
  fileprivate class func enter(_ blueprint:Blueprint, baseURL:URL? = nil, completion: @escaping ((HyperBlueprintResult) -> Void)) {
    if let baseURL = baseURL {
      let hyperdrive = self.init(blueprint: blueprint, baseURL: baseURL)
      let representor = hyperdrive.rootRepresentor()
      DispatchQueue.main.async {
        completion(.success((hyperdrive, representor)))
      }
    } else {
      let host = (blueprint.metadata).filter { metadata in metadata.name == "HOST" }.first
      if let host = host {
        if let baseURL = URL(string: host.value) {
          let hyperdrive = self.init(blueprint: blueprint, baseURL: baseURL)
          let representor = hyperdrive.rootRepresentor()
          DispatchQueue.main.async {
            completion(.success((hyperdrive, representor)))
          }
          return
        }
      }

      let error = NSError(domain: Hyperdrive.errorDomain, code: 0, userInfo: [
        NSLocalizedDescriptionKey: "Entering an API Blueprint hyperdrive without a base URL.",
      ])
      DispatchQueue.main.async {
        completion(.failure(error))
      }
    }
  }

  public required init(blueprint:Blueprint, baseURL:URL) {
    self.blueprint = blueprint
    self.baseURL = baseURL
  }

  fileprivate var resources:[Resource] {
    let resources = blueprint.resourceGroups.map { $0.resources }
    return resources.reduce([], +)
  }

  /// Returns a representor representing all available links
  open func rootRepresentor() -> Representor<HTTPTransition> {
    return Representor { builder in
      for resource in self.resources {
        let actions = resource.actions.filter { action in
          let hasAction = (action.relation != nil) && !action.relation!.isEmpty
          return hasAction && action.method == "GET"
        }

        for action in actions {
          let relativeURI = uriForAction(resource, action: action)
          let absoluteURI = absoluteURITemplate(self.baseURL.absoluteString, uriTemplate: relativeURI)
          let transition = HTTPTransition.from(resource: resource, action: action, URL: absoluteURI)
          builder.addTransition(action.relation!, transition)
        }
      }
    }
  }

  open override func constructRequest(_ uri: String, parameters: [String : Any]?) -> RequestResult {
    return super.constructRequest(uri, parameters: parameters).map { request in
      var request = request
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      return request
    }
  }

  open override func constructResponse(_ request: URLRequest, response: HTTPURLResponse, body: Data?) -> Representor<HTTPTransition>? {
    if let resource = resourceForResponse(response) {
      return Representor { builder in
        var uriTemplate = resource.actionForMethod(request.httpMethod ?? "GET")?.uriTemplate
        if (uriTemplate == nil) || !uriTemplate!.isEmpty {
          uriTemplate = resource.uriTemplate
        }

        let template = URITemplate(template: absoluteURITemplate(self.baseURL.absoluteString, uriTemplate: uriTemplate!))
        let parameters = template.extract(response.url!.absoluteString)

        self.addResponse(resource, parameters: parameters, request: request as URLRequest, response: response, body: body as Data?, builder: builder)

        if response.url != nil {
          var allowedMethods:[String]? = nil

          if let allow = response.allHeaderFields["Allow"] as? String {
            allowedMethods = allow.components(separatedBy: ",").map {
              $0.trimmingCharacters(in: .whitespaces)
            }
          }

          self.addTransitions(resource, parameters: parameters, builder: builder, allowedMethods: allowedMethods)
        }

        for link in response.links {
          if let relation = link.relationType {
            builder.addTransition(relation, uri: link.uri) { builder in
              builder.method = "GET"

              if let type = link.type {
                builder.suggestedContentTypes = [type]
              }
            }
          }
        }

        if builder.transitions["self"] == nil {
          if let URL = response.url?.absoluteString {
            builder.addTransition("self", uri: URL) { builder in
              builder.method = "GET"
            }
          }
        }
      }
    }

    return nil
  }

  open func resourceForResponse(_ response: HTTPURLResponse) -> Resource? {
    if let URL = response.url?.absoluteString {
      return resources.filter { resource in
        let template = URITemplate(template: absoluteURITemplate(baseURL.absoluteString, uriTemplate: resource.uriTemplate))
        let extract = template.extract(URL)
        return extract != nil
      }.first
    }

    return nil
  }

  open func actionForResource(_ resource:Resource, method:String) -> Action? {
    return resource.actions.filter { action in action.method == method }.first
  }

  func resource(named:String) -> Resource? {
    return resources.filter { resource in resource.name == named }.first
  }

  // MARK: -

  func addResponse(_ resource:Resource, parameters:[String:Any]?, request:URLRequest, response:HTTPURLResponse, body:Data?, builder:RepresentorBuilder<HTTPTransition>) {
    if let body = body {
      if response.mimeType == "application/json" {
        if let object = decodeJSON(body).value {
          addObjectResponse(resource, parameters: parameters, request: request, response: response, object: object, builder: builder)
        }
      }
    }
  }

  /// Returns any required URI Parameters for the given resource and attributes to determine the URI for the resource
  open func parameters(resource:Resource, attributes:[String:Any]) -> [String:Any]? {
    // By default, check if the attributes includes a URL we can use to extract the parameters
    if let url = attributes["url"] as? String {
      return resources.flatMap {
        URITemplate(template: $0.uriTemplate).extract(url)
      }.first
    }

    return nil
  }

  func addObjectResponse(_ resource:Resource, parameters:[String:Any]?, request:URLRequest, response:HTTPURLResponse, object:Any, builder:RepresentorBuilder<HTTPTransition>) {
    if let attributes = object as? [String:Any] {
      addAttributes([:], resource:resource, request: request, response: response, attributes: attributes, builder: builder)
    } else if let objects = object as? [[String:Any]] {  // An array of other resources
      if let typeSpecification = resource.typeSpecification {
        let name = typeSpecification["name"] as? String ?? ""
        if name == "array" {
          if let nestedTypes = typeSpecification["nestedTypes"] as? [[String:Any]] {
            if let literal = nestedTypes.first?["literal"] as? String {
              let relation = resource.actionForMethod(request.httpMethod ?? "GET")?.relation ?? "objects"
              if let embeddedResource = self.resource(named: literal) {
                for object in objects {
                  builder.addRepresentor(relation) { builder in
                    self.addObjectResponse(embeddedResource, parameters: parameters, request: request, response: response, object: object, builder: builder)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  func addObjectResponseOfResource(_ relation:String, resource:Resource, request:URLRequest, response:HTTPURLResponse, object:Any, builder:RepresentorBuilder<HTTPTransition>) {
    if let attributes = object as? [String:Any] {
      builder.addRepresentor(relation) { builder in
        self.addAttributes([:], resource: resource, request: request, response: response, attributes: attributes, builder: builder)
      }
    } else if let objects = object as? [[String:Any]] {
      for object in objects {
        addObjectResponseOfResource(relation, resource: resource, request: request, response: response, object: object, builder: builder)
      }
    }
  }

  func addAttributes(_ parameters:[String:Any]?, resource:Resource, request:URLRequest, response:HTTPURLResponse, attributes:[String:Any], builder:RepresentorBuilder<HTTPTransition>) {
    let action = actionForResource(resource, method: request.httpMethod!)

    func resourceForAttribute(_ key:String) -> Resource? {
      // TODO: Rewrite this to use proper refract structures
      if let dataStructure = resource.dataStructure {
        if let sections = dataStructure["sections"] as? [[String:Any]] {
          if let section = sections.first {
            if (section["class"] as? String ?? "") == "memberType" {
              if let members = section["content"] as? [[String:Any]] {
                func findMember(_ member:[String:Any]) -> Bool {
                  if let content = member["content"] as? [String:Any] {
                    if let name = content["name"] as? [String:String] {
                      if let literal = name["literal"] {
                        return literal == key
                      }
                    }
                  }

                  return false
                }

                if let member = members.filter(findMember).first {
                  if let content = member["content"] as? [String:Any] {
                    if let definition = content["valueDefinition"] as? [String:Any] {
                      if let typeDefinition = definition["typeDefinition"] as? [String:Any] {
                        if let typeSpecification = typeDefinition["typeSpecification"] as? [String:Any] {
                          if let name = typeSpecification["name"] as? String {
                            if name == "array" {
                              if let literal = (typeSpecification["nestedTypes"] as? [[String:Any]])?.first?["literal"] as? String {
                                return self.resource(named:literal)
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      
      return nil
    }
      

    for (key, value) in attributes {
      if let resource = resourceForAttribute(key) {
        self.addObjectResponseOfResource(key, resource:resource, request: request, response: response, object: value, builder: builder)
      } else {
        builder.addAttribute(key, value: value)
      }
    }

    let params = (parameters ?? [:]) + (self.parameters(resource:resource, attributes:attributes) ?? [:])
    addTransitions(resource, parameters:params, builder: builder)
  }

  func addTransitions(_ resource:Resource, parameters:[String:Any]?, builder:RepresentorBuilder<HTTPTransition>, allowedMethods:[String]? = nil) {
    let resourceURI = absoluteURITemplate(self.baseURL.absoluteString, uriTemplate: URITemplate(template: resource.uriTemplate).expand(parameters ?? [:]))

    for action in resource.actions {
      var actionURI = resourceURI

      if action.uriTemplate != nil && !action.uriTemplate!.isEmpty {
        actionURI = absoluteURITemplate(self.baseURL.absoluteString, uriTemplate: URITemplate(template: action.uriTemplate!).expand(parameters ?? [:]))
      }

      if let relation = action.relation {
        let transition = HTTPTransition.from(resource:resource, action:action, URL:actionURI)
        if let allowedMethods = allowedMethods {
          if !allowedMethods.contains(transition.method) {
            continue
          }
        }
        builder.addTransition(relation, transition)
      }
    }
  }
}

// Merge two dictionaries together
func +<K,V>(lhs:Dictionary<K,V>, rhs:Dictionary<K,V>) -> Dictionary<K,V> {
  var dictionary = [K:V]()

  for (key, value) in rhs {
    dictionary[key] = value
  }

  for (key, value) in lhs {
    dictionary[key] = value
  }

  return dictionary
}
