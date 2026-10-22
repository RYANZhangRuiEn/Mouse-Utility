import Foundation

protocol ReleaseRequest: AnyObject { func cancel() }

/// A bounded, unauthenticated GitHub request, with no cookies or stored credentials.
final class GitHubReleaseRequest: NSObject, ReleaseRequest, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var completion: ((Result<Data,Error>) -> Void)?
    static func request(tag: String) -> URLRequest {
        var request = URLRequest(url: ReleaseCatalog.api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MouseRing/" + tag, forHTTPHeaderField: "User-Agent")
        return request
    }
    init(tag: String, completion: @escaping (Result<Data,Error>) -> Void) {
        super.init(); self.completion = completion
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session!.dataTask(with: Self.request(tag:tag)); task!.resume()
    }
    func cancel() { completion = nil; task?.cancel(); session?.invalidateAndCancel(); session = nil; task = nil }
    private func finish(_ result: Result<Data,Error>) {
        let callback = completion; cancel(); callback?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A repository move requires a source change, rather than silently following a new host.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == ReleaseCatalog.api else {
            completionHandler(.cancel); finish(.failure(ReleaseCheckError.invalidResponse)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure([403,429].contains(http.statusCode) ? ReleaseCheckError.rateLimited : ReleaseCheckError.serviceUnavailable)); return
        }
        guard response.expectedContentLength <= Int64(ReleaseCatalog.maximumBytes) else {
            completionHandler(.cancel); finish(.failure(ReleaseCheckError.invalidResponse)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= ReleaseCatalog.maximumBytes else { finish(.failure(ReleaseCheckError.invalidResponse)); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? .success(data) : .failure(ReleaseCheckError.serviceUnavailable))
    }
}
