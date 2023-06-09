//
//  WebRepositoryProvider.swift
//  
//
//  Created by Chocoford on 2023/3/17.
//

import Foundation
#if !os(Linux)
import Combine
#endif

import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LogOption {
    case request
    case response
    case data
    case error
}

public protocol WebRepositoryProvider {
    var logLevel: [LogOption] { get set }
    var logger: Logger { get }
    var session: URLSession { get }
    var baseURL: String { get }
    var bgQueue: DispatchQueue { get }
    var responseDataDecoder: JSONDecoder { get set }
}

extension WebRepositoryProvider {
    var logLevel: [LogOption] { [.error] }
    public func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) async throws -> Value where Value: Decodable {
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            if logLevel.contains(.request) { logger.info("\(request.prettyDescription)") }
            let (data, response) = try await session.data(for: request)
            if logLevel.contains(.response) { logger.info("\(response)") }
            guard let code = (response as? HTTPURLResponse)?.statusCode else {
                throw APIError.unexpectedResponse
            }
            let dataString = data.prettyJSONStringified()
            guard httpCodes.contains(code) else {
                let error = APIError.httpCode(code,
                                              reason: dataString,
                                              headers: (response as? HTTPURLResponse)?.allHeaderFields)
                throw error
            }
                        
            if logLevel.contains(.data) {
                if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                   let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]) {
                    logger.info("\(String(data: data, encoding: .utf8) ?? "")")
                } else {
                    logger.info("\(String(data: data, encoding: .utf8) ?? "")")
                }
            }
            do {
                let decoded = try responseDataDecoder.decode(Value.self, from: data)
                return decoded
            } catch {
                if Value.self == String.self {
                    logger.warning("warning: \(error)")
                    return (String(data: data, encoding: .utf8) ?? "") as! Value
                } else {
                    throw error
                }
            }
        } catch {
            if logLevel.contains(.error) {
                logger.error("\(error)")
            }
            throw error
        }
    }
}

//class SessionDelegate: NSObject, URLSessionTaskDelegate {
//    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
//        print("didComplete", task, error)
//    }
//}

#if !os(Linux)
// MARK: - Combine support
extension WebRepositoryProvider {
    public func call<Value>(endpoint: APICall, httpCodes: HTTPCodes = .success) -> AnyPublisher<Value, Error> where Value: Decodable {
        do {
            let request = try endpoint.urlRequest(baseURL: baseURL)
            logger.info("\(request.prettyDescription)")
            return session
                .dataTaskPublisher(for: request)
                .requestJSON(httpCodes: httpCodes, decoder: responseDataDecoder, logger: logger, logLevel: logLevel)
                .mapError { error in
                    if logLevel.contains(.error) {
                        logger.error("\(error)")
                    }
                    return error
                }
                .eraseToAnyPublisher()
        } catch {
            if logLevel.contains(.error) {
                logger.error("\(error)")
            }
            return Fail<Value, Error>(error: error).eraseToAnyPublisher()
        }
    }
}

extension Publisher where Output == URLSession.DataTaskPublisher.Output {
    func requestData(httpCodes: HTTPCodes = .success,
                     logger: Logger? = nil,
                     logLevel: [LogOption] = [.data, .response]) -> AnyPublisher<Data, Error> {
        return tryMap {
            assert(!Thread.isMainThread)
            guard let code = ($0.1 as? HTTPURLResponse)?.statusCode else {
                throw APIError.unexpectedResponse
            }
            
            let dataString = String(data: $0.data, encoding: .utf8) ?? ""
            
            guard httpCodes.contains(code) else {
                let error = APIError.httpCode(code,
                                              reason: dataString,
                                              headers: ($0.response as? HTTPURLResponse)?.allHeaderFields)
                logger?.error("\(error.errorDescription ?? "")")
                throw error
            }
            logger?.debug("\(dataString)")

            return $0.0
        }
//            .extractUnderlyingError()
            .eraseToAnyPublisher()
    }
}

private extension Publisher where Output == URLSession.DataTaskPublisher.Output {
    func requestJSON<Value>(httpCodes: HTTPCodes,
                            decoder: JSONDecoder,
                            logger: Logger? = nil,
                            logLevel: [LogOption] = [.data, .response]) -> AnyPublisher<Value, Error> where Value: Decodable {

        return requestData(httpCodes: httpCodes, logger: logger, logLevel: logLevel)
            .decode(type: Value.self, decoder: decoder)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    func printResult(disabled: Bool = false) -> AnyPublisher<Self.Output, Self.Failure> {
        return self
            .map({ (data, res) in
                if disabled { return (data, res) }
                let json = try? JSONSerialization.jsonObject(with: data, options: [])
                if let objJson = json as? [String: Any] {
                    dump(objJson.debugDescription, name: "result")
                } else if let arrJson = json as? [[String: Any]] {
                    dump(arrJson, name: "result")
                }
                return (data, res)
            })
            .eraseToAnyPublisher()
    }
}

#endif
