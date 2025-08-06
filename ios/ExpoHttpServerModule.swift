import Criollo
import ExpoModulesCore

public class ExpoHttpServerModule: Module {
    private let server = CRHTTPServer()
    private var port: Int?
    private var stopped = false
    private let responsesQueue = DispatchQueue(label: "responses.queue", attributes: .concurrent)
    private var _responses = [String: CRResponse]()
    private var bgTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    
    // Thread-safe responses access methods
    private func getResponse(for uuid: String) -> CRResponse? {
        return responsesQueue.sync { _responses[uuid] }
    }
    
    private func setResponse(_ response: CRResponse?, for uuid: String) {
        responsesQueue.async(flags: .barrier) {
            self._responses[uuid] = response
        }
    }
    
    private func removeResponse(for uuid: String) -> CRResponse? {
        return responsesQueue.sync(flags: .barrier) {
            return _responses.removeValue(forKey: uuid)
        }
    }
    
    private func removeAllResponses() -> [String: CRResponse] {
        return responsesQueue.sync(flags: .barrier) {
            let currentResponses = _responses
            _responses.removeAll()
            return currentResponses
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopServer()
    }

    public func definition() -> ModuleDefinition {
        Name("ExpoHttpServer")

        Events("onStatusUpdate", "onRequest")

        Function("setup", setupHandler)
        Function("start", startHandler)
        Function("route", routeHandler)
        Function("respond", respondHandler)
        Function("stop", stopHandler)
    }

    private func setupHandler(port: Int) {
        guard port > 0 && port <= 65535 else {
            sendEvent(
                "onStatusUpdate",
                [
                    "status": "ERROR",
                    "message": "Invalid port number. Port must be between 1 and 65535",
                ])
            return
        }
        self.port = port
    }

    private func startHandler() {
        // Remove existing observer to prevent duplicates
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if !self.stopped {
                self.startServer(status: "RESUMED", message: "Server resumed")
            }
        }
        stopped = false
        startServer(status: "STARTED", message: "Server started")
    }

    private func routeHandler(path: String, method: String, uuid: String) {
        // Validate UUID format
        guard !uuid.isEmpty && uuid.count <= 100 else {
            print("ExpoHttpServer: Invalid UUID format")
            return
        }
        
        server.add(
            path,
            block: { (req, res, next) in
                // Use background queue for processing to avoid blocking main thread
                DispatchQueue.global(qos: .userInitiated).async {
                    var bodyString = "{}"
                    if let body = req.body,
                        let bodyData = try? JSONSerialization.data(withJSONObject: body)
                    {
                        bodyString = String(data: bodyData, encoding: .utf8) ?? "{}"
                    }
                    
                    // Thread-safe response storage
                    self.setResponse(res, for: uuid)
                    
                    DispatchQueue.main.async {
                        self.sendEvent(
                            "onRequest",
                            [
                                "uuid": uuid,
                                "method": req.method.toString(),
                                "path": path,
                                "body": bodyString,
                                "headersJson": req.allHTTPHeaderFields.jsonString,
                                "paramsJson": req.query.jsonString,
                                "cookiesJson": req.cookies?.jsonString ?? "{}",
                            ])
                    }
                }
            }, recursive: false, method: CRHTTPMethod.fromString(method))
    }

    private func respondHandler(
        udid: String,
        statusCode: Int,
        statusDescription: String,
        contentType: String,
        headers: [String: String],
        body: String
    ) {
        // Validate input parameters
        guard !udid.isEmpty,
              statusCode >= 100 && statusCode <= 599 else {
            print("ExpoHttpServer: Invalid response parameters - udid: \(udid), statusCode: \(statusCode)")
            return
        }
        
        // Get and remove response atomically to prevent memory leaks
        guard let response = removeResponse(for: udid) else {
            print("ExpoHttpServer: Response not found for udid: \(udid)")
            return
        }
        
        // Process response on main queue
        DispatchQueue.main.async {
            response.setStatusCode(UInt(statusCode), description: statusDescription)
            response.setValue(contentType.isEmpty ? "text/plain" : contentType, forHTTPHeaderField: "Content-type")
            
            if let bodyData = body.data(using: .utf8) {
                response.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
                
                // Validate and set headers
                for (key, value) in headers {
                    guard !key.isEmpty else { continue }
                    response.setValue(value, forHTTPHeaderField: key)
                }
                
                response.send(body)
            } else {
                print("ExpoHttpServer: Failed to encode response body for udid: \(udid)")
                response.setStatusCode(500, description: "Internal Server Error")
                response.send("Failed to encode response body")
            }
        }
    }

    private func stopHandler() {
        stopped = true
        
        // Get all pending responses and clear them atomically
        let pendingResponses = removeAllResponses()
        
        // Send error responses to any pending requests on main queue
        if !pendingResponses.isEmpty {
            DispatchQueue.main.async {
                for (udid, response) in pendingResponses {
                    response.setStatusCode(503, description: "Service Unavailable")
                    response.send("Server is shutting down")
                    print("ExpoHttpServer: Sent shutdown response for udid: \(udid)")
                }
            }
        }
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        
        stopServer(status: "STOPPED", message: "Server stopped")
    }

    private func startServer(status: String, message: String) {
        stopServer()
        
        guard let port = port else {
            sendEvent(
                "onStatusUpdate",
                [
                    "status": "ERROR",
                    "message": "Can't start server: port not configured",
                ])
            return
        }
        
        var error: NSError?
        let success = server.startListening(&error, portNumber: UInt(port))
        
        if let error = error {
            print("ExpoHttpServer: Failed to start server on port \(port): \(error.localizedDescription)")
            sendEvent(
                "onStatusUpdate",
                [
                    "status": "ERROR",
                    "message": "Failed to start server on port \(port): \(error.localizedDescription)",
                ])
        } else if success {
            beginBackgroundTask()
            print("ExpoHttpServer: Successfully started server on port \(port)")
            sendEvent(
                "onStatusUpdate",
                [
                    "status": status,
                    "message": message,
                ])
        } else {
            print("ExpoHttpServer: Unknown error starting server on port \(port)")
            sendEvent(
                "onStatusUpdate",
                [
                    "status": "ERROR",
                    "message": "Unknown error starting server on port \(port)",
                ])
        }
    }

    private func stopServer(status: String? = nil, message: String? = nil) {
        server.stopListening()
        endBackgroundTask()
        
        if let status = status, let message = message {
            print("ExpoHttpServer: \(message)")
            sendEvent(
                "onStatusUpdate",
                [
                    "status": status,
                    "message": message,
                ])
        }
    }

    private func beginBackgroundTask() {
        // Only create background task if one doesn't already exist
        guard bgTaskIdentifier == UIBackgroundTaskIdentifier.invalid else {
            return
        }
        
        self.bgTaskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "ExpoHttpServerBgTask",
            expirationHandler: { [weak self] in
                print("ExpoHttpServer: Background task expired, pausing server")
                self?.stopServer(status: "PAUSED", message: "Server paused due to background task expiration")
            })
        
        if bgTaskIdentifier == UIBackgroundTaskIdentifier.invalid {
            print("ExpoHttpServer: Failed to create background task")
        } else {
            print("ExpoHttpServer: Background task created successfully")
        }
    }

    private func endBackgroundTask() {
        guard bgTaskIdentifier != UIBackgroundTaskIdentifier.invalid else {
            return
        }
        
        UIApplication.shared.endBackgroundTask(bgTaskIdentifier)
        bgTaskIdentifier = UIBackgroundTaskIdentifier.invalid
        print("ExpoHttpServer: Background task ended")
    }
}

extension Dictionary {
    var jsonString: String {
        do {
            let data = try JSONSerialization.data(withJSONObject: self, options: [])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            print("ExpoHttpServer: Failed to serialize dictionary to JSON: \(error)")
            return "{}"
        }
    }
}

extension CRHTTPMethod {
    func toString() -> String {
        switch self {
        case .post:
            return "POST"
        case .put:
            return "PUT"
        case .delete:
            return "DELETE"
        default:
            return "GET"
        }
    }

    static func fromString(_ string: String) -> Self {
        var httpMethod: CRHTTPMethod
        switch string {
        case "POST":
            httpMethod = .post
        case "PUT":
            httpMethod = .put
        case "DELETE":
            httpMethod = .delete
        default:
            httpMethod = .get
        }
        return httpMethod
    }
}
