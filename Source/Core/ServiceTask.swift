//
//  ServiceTask.swift
//  ELWebService
//
//  Created by Angelo Di Paolo on 2/25/15.
//  Copyright (c) 2015 WalmartLabs. All rights reserved.
//

import Foundation


/**
 A lightweight wrapper around `NSURLSessionDataTask` that provides a chainable
 API for processing the result of a data task. A `ServiceTask` instance can be
 cancelled and suspended like a data task as well as queried for current state
 via the `state` property.
*/
@objc public final class ServiceTask: NSObject {
    public typealias ResponseProcessingHandler = (NSData?, NSURLResponse?) -> ServiceTaskResult
    
    /// A closure type alias for a success handler.
    public typealias UpdateUIHandler = (Any?) -> Void

    /// A closure type alias for an error handler.
    public typealias ErrorHandler = (ErrorType) -> Void
    
    /// State of the service task.
    public var state: NSURLSessionTaskState {
        if let state = dataTask?.state {
            return state
        } else {
            return .Suspended
        }
    }
    
    private var request: Request
    
    private var urlRequest: NSURLRequest {
        return request.urlRequestValue
    }
    
    /// Dispatch queue that queues up and dispatches handler blocks
    private let handlerQueue: NSOperationQueue
    
    /// Session data task that refers the lifetime of the request.
    private var dataTask: NSURLSessionDataTask?
    
    /// Result of the service task
    private var taskResult: ServiceTaskResult? {
        didSet {
            // Use observer to watch for error result to send to passthrough
            guard let result = taskResult else { return }
            switch result {
            case .Failure(let error): configuration?.passthroughDelegate?.serviceResultFailure(error)
            case .Empty, .Value(_): return
            }
        }
    }
    
    /// Response body data
    private var responseData: NSData?
    
    /// URL response
    private var urlResponse: NSURLResponse?
    
    /// Type responsible for creating NSURLSessionDataTask objects
    private weak var dataTaskSource: SessionDataTaskDataSource?
    
    /// Service configuration
    internal weak var configuration: ServiceConfiguration?
    
    // MARK: Intialization
    
    /**
     Initialize a ServiceTask value to fulfill an HTTP request.
    
     - parameter urlRequestEncoder: Value responsible for encoding a NSURLRequest
       instance to send.
     - parameter dataTaskSource: Object responsible for creating a
       NSURLSessionDataTask used to send the NSURLRequset.
    */
    init(request: Request, dataTaskSource: SessionDataTaskDataSource) {
        self.request = request
        self.dataTaskSource = dataTaskSource
        self.handlerQueue = {
            let queue = NSOperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.suspended = true
            return queue
        }()
    }
    
    deinit {
        handlerQueue.cancelAllOperations()
    }
}

// MARK: - Request API

extension ServiceTask {
    /// TODO: Needs docs
    public func setParameters(parameters: [String: AnyObject], encoding: Request.ParameterEncoding? = nil) -> Self {
        request.parameters = parameters
        request.parameterEncoding = encoding ?? .Percent
        
        if encoding == .JSON {
            request.contentType = Request.ContentType.json
        }
        
        return self
    }
    
    /// TODO: Needs docs
    public func setBody(data: NSData) -> Self {
        request.body = data
        return self
    }
    
    /// TODO: Needs docs
    public func setJSON(json: AnyObject) -> Self {
        request.contentType = Request.ContentType.json
        request.body = try? NSJSONSerialization.dataWithJSONObject(json, options: NSJSONWritingOptions(rawValue: 0))
        return self
    }
    
    /// TODO: Needs docs
    public func setHeaders(headers: [String: String]) -> Self {
        request.headers = headers
        return self
    }
    
    /// TODO: Needs docs
    public func setHeaderValue(value: String, forName name: String) -> Self {
        request.headers[name] = value
        return self
    }
    
    /// TODO: Needs docs
    public func setCachePolicy(cachePolicy: NSURLRequestCachePolicy) -> Self {
        request.cachePolicy = cachePolicy
        return self
    }
    
    /// TODO: Needs docs
    public func setParameterEncoding(encoding: Request.ParameterEncoding) -> Self {
        request.parameterEncoding = encoding
        return self
    }
}

// MARK: - NSURLSesssionDataTask

extension ServiceTask {
    /// Resume the underlying data task.
    public func resume() -> Self {
        if dataTask == nil {
            dataTask = dataTaskSource?.dataTaskWithRequest(urlRequest) { data, response, error in
                self.handleResponse(response, data: data, error: error)
            }
        }
        
        dataTask?.resume()
        return self
    }
    
    /// Suspend the underlying data task.
    public func suspend() {
        dataTask?.suspend()
    }
    
    /// Cancel the underlying data task.
    public func cancel() {
        dataTask?.cancel()
    }
    
    /// Handle the response and kick off the handler queue
    internal func handleResponse(response: NSURLResponse?, data: NSData?, error: NSError?) {
        urlResponse = response
        responseData = data
        
        if let error = error {
            taskResult = ServiceTaskResult.Failure(error)
        }
        
        handlerQueue.suspended = false
    }
}

// MARK: - Response API

extension ServiceTask {
    /**
     Add a response handler to be called on background thread after a successful
     response has been received.
    
     - parameter handler: Response handler to execute upon receiving a response.
     - returns: Self instance to support chaining.
    */
    public func response(handler: ResponseProcessingHandler) -> Self {
        handlerQueue.addOperationWithBlock {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .Failure(_): return // bail out to avoid next handler from running
                case .Value(_): break
                case .Empty: break
                }
            }
            
            self.taskResult = handler(self.responseData, self.urlResponse)
        }

        return self
    }
    
    /**
     Add a handler that runs on the main thread and is responsible for updating 
     the UI with a given value. The handler is only called if a previous response 
     handler in the chain does **not** return a `.Failure` value.
     
     If a response handler returns a value via ServiceTaskResult.Value the
     associated value will be passed to the update UI handler.
    
     - parameter handler: The closure to execute as the updateUI handler.
     - returns: Self instance to support chaining.
    */
    public func updateUI(handler: UpdateUIHandler) -> Self {
        handlerQueue.addOperationWithBlock {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .Value(let value):
                    dispatch_async(dispatch_get_main_queue()) {
                        self.configuration?.passthroughDelegate?.updateUIBegin(self.urlResponse)
                        handler(value)
                        self.configuration?.passthroughDelegate?.updateUIEnd(self.urlResponse)
                    }
                case .Empty:
                    dispatch_async(dispatch_get_main_queue()) {
                        self.configuration?.passthroughDelegate?.updateUIBegin(self.urlResponse)
                        handler(nil)
                        self.configuration?.passthroughDelegate?.updateUIEnd(self.urlResponse)
                    }
                case .Failure(_): break
                }
            }
        }
        
        return self
    }
}

// MARK: - JSON

extension ServiceTask {
    /// A closure type alias for handling the response as JSON.
    public typealias JSONHandler = (AnyObject) -> ServiceTaskResult
    
    /**
     Add a response handler to serialize the response body as a JSON object. The
     handler will be dispatched to a background thread.
    
     - parameter handler: Response handler to execute upon receiving a response.
     - returns: Self instance to support chaining.
    */
    public func responseJSON(handler: JSONHandler) -> Self {
        return response { data, response in
            if let data = data {
                do {
                    let json = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions.AllowFragments)
                    return handler(json)
                } catch let jsonError as NSError {
                    return .Failure(jsonError)
                } catch {
                    fatalError()
                }
            } else {
                return .Failure(ServiceTaskError.JSONSerializationFailedNilResponseBody)
            }
        }
    }
}

// MARK: - Error Handling

extension ServiceTask {
    /**
    Add a response handler to be called if a request results in an error.
    
    - parameter handler: Error handler to execute when an error occurs.
    - returns: Self instance to support chaining.
    */
    public func responseError(handler: ErrorHandler) -> Self {
        handlerQueue.addOperationWithBlock {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .Failure(let error): handler(error)
                case .Value(_): break
                case .Empty: break
                }
            }
        }
        
        return self
    }
    
    /**
     Add a response handler to be called if a request results in an error. Handler
     will be called on the main thread.
     
     - parameter handler: Error handler to execute when an error occurs.
     - returns: Self instance to support chaining.
    */
    public func updateErrorUI(handler: ErrorHandler) -> Self {
        handlerQueue.addOperationWithBlock {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .Failure(let error):
                    dispatch_async(dispatch_get_main_queue()) {
                        handler(error)
                    }
                case .Value(_): break
                case .Empty: break
                }
            }
        }
        
        return self
    }
}

// MARK: - Errors

/// Errors that can occur when processing a response
public enum ServiceTaskError: ErrorType {
    /// Failed to serialize a response body as JSON due to the data being nil.
    case JSONSerializationFailedNilResponseBody
}
