package expo.modules.httpserver

import androidx.core.os.bundleOf
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import com.safframework.server.core.AndroidServer
import com.safframework.server.core.Server
import com.safframework.server.core.http.HttpMethod
import com.safframework.server.core.http.Request
import com.safframework.server.core.http.Response
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import android.util.Log

class ExpoHttpServerModule : Module() {
  data class SimpleHttpResponse(
    val statusCode: Int,
    val statusDescription: String,
    val contentType: String,
    val headers: HashMap<String, String>,
    val body: String
  )

  private var server: Server? = null
  private var started = false
  private val responses = ConcurrentHashMap<String, SimpleHttpResponse>()
  private val pendingRequests = ConcurrentHashMap<String, CountDownLatch>()
  private val TAG = "ExpoHttpServer"

  override fun definition() = ModuleDefinition {

    Name("ExpoHttpServer")

    Events("onStatusUpdate", "onRequest")

    Function("setup") { port: Int ->
      try {
        if (port <= 0 || port > 65535) {
          sendEvent("onStatusUpdate", bundleOf(
            "status" to "ERROR",
            "message" to "Invalid port number. Port must be between 1 and 65535"
          ))
          return@Function
        }
        
        server = AndroidServer.Builder {
          port {
            port
          }
        }.build()
        Log.d(TAG, "Server setup on port $port")
      } catch (e: Exception) {
        Log.e(TAG, "Failed to setup server", e)
        sendEvent("onStatusUpdate", bundleOf(
          "status" to "ERROR",
          "message" to "Failed to setup server: ${e.message}"
        ))
      }
    }

    Function("route") { path: String, method: String, uuid: String ->
      try {
        // Validate input parameters
        if (uuid.isEmpty() || uuid.length > 100) {
          Log.w(TAG, "Invalid UUID format: $uuid")
          return@Function
        }
        
        server = server?.request(HttpMethod.getMethod(method), path) { request: Request, response: Response ->
          try {
            val headers: Map<String, String> = request.headers()
            val params: Map<String, String> = request.params()
            val cookies: Map<String, String> = request.cookies().associate { it.name() to it.value() }
            
            // Create countdown latch for this request
            val latch = CountDownLatch(1)
            pendingRequests[uuid] = latch
            
            sendEvent("onRequest", bundleOf(
              "uuid" to uuid,
              "method" to request.method().name,
              "path" to request.url(),
              "body" to request.content(),
              "headersJson" to JSONObject(headers).toString(),
              "paramsJson" to JSONObject(params).toString(),
              "cookiesJson" to JSONObject(cookies).toString(),
            ))
            
            // Wait for response with timeout (30 seconds)
            val responseReceived = latch.await(30, TimeUnit.SECONDS)
            pendingRequests.remove(uuid)
            
            if (!responseReceived) {
              Log.w(TAG, "Request timeout for uuid: $uuid")
              response.setBodyText("Request timeout")
              response.setStatus(408) // Request Timeout
              response.addHeader("Content-Type", "text/plain")
              return@request response
            }
            
            val res = responses.remove(uuid)
            if (res != null) {
              response.setBodyText(res.body)
              response.setStatus(res.statusCode)
              response.addHeader("Content-Length", res.body.length.toString())
              response.addHeader("Content-Type", res.contentType.ifEmpty { "text/plain" })
              
              for ((key, value) in res.headers) {
                if (key.isNotEmpty()) {
                  response.addHeader(key, value)
                }
              }
            } else {
              Log.e(TAG, "Response not found for uuid: $uuid")
              response.setBodyText("Internal Server Error")
              response.setStatus(500)
              response.addHeader("Content-Type", "text/plain")
            }
            
            return@request response
          } catch (e: Exception) {
            Log.e(TAG, "Error processing request", e)
            response.setBodyText("Internal Server Error")
            response.setStatus(500)
            response.addHeader("Content-Type", "text/plain")
            return@request response
          }
        }
      } catch (e: Exception) {
        Log.e(TAG, "Failed to add route", e)
      }
    }

    Function("start") {
      try {
        if (server == null) {
          sendEvent("onStatusUpdate", bundleOf(
            "status" to "ERROR",
            "message" to "Server not setup / port not configured"
          ))
        } else {
          if (!started) {
            started = true
            server?.start()
            Log.d(TAG, "Server started successfully")
            sendEvent("onStatusUpdate", bundleOf(
              "status" to "STARTED",
              "message" to "Server started"
            ))
          }
        }
      } catch (e: Exception) {
        started = false
        Log.e(TAG, "Failed to start server", e)
        sendEvent("onStatusUpdate", bundleOf(
          "status" to "ERROR",
          "message" to "Failed to start server: ${e.message}"
        ))
      }
    }

    Function("respond") { uuid: String,
                          statusCode: Int,
                          statusDescription: String,
                          contentType: String,
                          headers: HashMap<String, String>,
                          body: String ->
      try {
        // Validate input parameters
        if (uuid.isEmpty() || statusCode < 100 || statusCode > 599) {
          Log.w(TAG, "Invalid response parameters - uuid: $uuid, statusCode: $statusCode")
          return@Function
        }
        
        responses[uuid] = SimpleHttpResponse(statusCode, statusDescription, contentType, headers, body)
        
        // Signal that response is ready
        pendingRequests[uuid]?.countDown()
      } catch (e: Exception) {
        Log.e(TAG, "Failed to set response", e)
      }
    }

    Function("stop") {
      try {
        started = false
        
        // Cancel all pending requests
        for ((uuid, latch) in pendingRequests) {
          responses[uuid] = SimpleHttpResponse(503, "Service Unavailable", "text/plain", hashMapOf(), "Server is shutting down")
          latch.countDown()
        }
        pendingRequests.clear()
        responses.clear()
        
        server?.close()
        Log.d(TAG, "Server stopped")
        sendEvent("onStatusUpdate", bundleOf(
          "status" to "STOPPED",
          "message" to "Server stopped"
        ))
      } catch (e: Exception) {
        Log.e(TAG, "Error stopping server", e)
        sendEvent("onStatusUpdate", bundleOf(
          "status" to "ERROR",
          "message" to "Error stopping server: ${e.message}"
        ))
      }
    }
  }
}