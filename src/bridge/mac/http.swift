// The request head the Bridge reads from a VM, parsed apart from the socket
// code so tests/fuzz can feed it anything.
import Foundation

struct HTTPRequest {
  let method: String, path: String
  let query: [URLQueryItem]
  let headers: [String: String]   // names lowercased
}

/// The head up to (not including) the blank line; nil: not a request line.
func parseHead(_ head: Data) -> HTTPRequest? {
  let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
  let parts = lines[0].split(separator: " ")
  guard parts.count == 3 else { return nil }
  var headers: [String: String] = [:]
  for l in lines.dropFirst() {
    if let c = l.firstIndex(of: ":") {
      headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
  }
  let url = URLComponents(string: String(parts[1]))
  return HTTPRequest(method: String(parts[0]), path: url?.path ?? "", query: url?.queryItems ?? [], headers: headers)
}

/// The /proof nonce: 32 lowercase hex digits, else nil.
func proofNonce(_ query: [URLQueryItem]) -> String? {
  guard let n = query.first(where: { $0.name == "nonce" })?.value, n.count == 32,
        n.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
  return n
}

/// Content-Length as a size; nil when it is not a number or below zero.
func contentLength(_ headers: [String: String]) -> Int? {
  guard let n = Int(headers["content-length"] ?? "0"), n >= 0 else { return nil }
  return n
}
