@tool
class_name AINetGuard
extends RefCounted

## Blocks SSRF-ish targets for model-driven web fetch (localhost, private nets, metadata).


static func assert_public_http_url(url: String) -> Dictionary:
	## Returns { "ok": bool, "error": String, "url": String }
	var u := url.strip_edges()
	if u.is_empty():
		return _bad("URL is empty.")
	if u.contains("\n") or u.contains("\r") or u.contains(" "):
		return _bad("URL contains invalid characters.")
	if not (u.begins_with("http://") or u.begins_with("https://")):
		return _bad("Only http(s) URLs are allowed.")

	var parsed := _parse(u)
	if parsed.is_empty():
		return _bad("Could not parse URL.")

	var host: String = parsed["host"]
	if host.is_empty():
		return _bad("URL host is empty.")

	var host_err := _check_host(host)
	if not host_err.is_empty():
		return _bad(host_err)

	return {"ok": true, "error": "", "url": u}


static func is_loopback_or_private_host(host: String) -> bool:
	return not _check_host(host).is_empty()


static func _check_host(host_raw: String) -> String:
	var host := host_raw.strip_edges().to_lower()
	# Strip IPv6 brackets if present
	if host.begins_with("[") and host.ends_with("]"):
		host = host.substr(1, host.length() - 2)

	if host.is_empty():
		return "Empty host."

	# Obvious local names
	if host == "localhost" or host == "0.0.0.0" or host == "::" or host == "::1":
		return "Refusing local/loopback host: %s" % host
	if host.ends_with(".localhost") or host.ends_with(".local") or host.ends_with(".internal"):
		return "Refusing internal host: %s" % host
	if host == "metadata" or host == "metadata.google.internal" \
			or host.ends_with(".metadata.google.internal"):
		return "Refusing cloud metadata host: %s" % host

	# Literal IPs
	if _is_ipv4(host):
		if _ipv4_is_non_public(host):
			return "Refusing non-public IPv4 address: %s" % host
		return ""
	if host.contains(":"): # rough IPv6
		if _ipv6_is_non_public(host):
			return "Refusing non-public IPv6 address: %s" % host
		return ""

	# Resolve hostname and reject private results (best-effort).
	var resolved := _resolve_ips(host)
	for ip in resolved:
		if _is_ipv4(ip) and _ipv4_is_non_public(ip):
			return "Refusing host %s (resolves to non-public IP %s)" % [host, ip]
		if ip.contains(":") and _ipv6_is_non_public(ip):
			return "Refusing host %s (resolves to non-public IP %s)" % [host, ip]

	return ""


static func _resolve_ips(host: String) -> PackedStringArray:
	var out: PackedStringArray = []
	# Godot IP.resolve_hostname returns a single address string (or empty).
	var a := IP.resolve_hostname(host, IP.TYPE_IPV4)
	if typeof(a) == TYPE_STRING and not str(a).is_empty() and str(a) != "*":
		out.append(str(a))
	var b := IP.resolve_hostname(host, IP.TYPE_IPV6)
	if typeof(b) == TYPE_STRING and not str(b).is_empty() and str(b) != "*":
		out.append(str(b))
	# Some versions return PackedStringArray from resolve_hostname_addresses
	if IP.has_method("resolve_hostname_addresses"):
		var many: Variant = IP.call("resolve_hostname_addresses", host)
		if typeof(many) == TYPE_PACKED_STRING_ARRAY:
			for ip in many:
				if not out.has(str(ip)):
					out.append(str(ip))
		elif typeof(many) == TYPE_ARRAY:
			for ip in many:
				var s := str(ip)
				if not out.has(s):
					out.append(s)
	return out


static func _is_ipv4(host: String) -> bool:
	var parts := host.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if not p.is_valid_int():
			return false
		var n := int(p)
		if n < 0 or n > 255:
			return false
	return true


static func _ipv4_is_non_public(ip: String) -> bool:
	var parts := ip.split(".")
	if parts.size() != 4:
		return true
	var a := int(parts[0])
	var b := int(parts[1])
	# 0.0.0.0/8, loopback 127/8, link-local 169.254/16, private nets, CGNAT, multicast, reserved
	if a == 0 or a == 127 or a >= 224:
		return true
	if a == 10:
		return true
	if a == 169 and b == 254:
		return true
	if a == 172 and b >= 16 and b <= 31:
		return true
	if a == 192 and b == 168:
		return true
	if a == 100 and b >= 64 and b <= 127: # CGNAT
		return true
	if a == 198 and (b == 18 or b == 19): # benchmarking
		return true
	return false


static func _ipv6_is_non_public(ip: String) -> bool:
	var h := ip.to_lower()
	if h == "::1" or h == "::":
		return true
	# Unique local fc00::/7, link-local fe80::/10
	if h.begins_with("fc") or h.begins_with("fd") or h.begins_with("fe8") \
			or h.begins_with("fe9") or h.begins_with("fea") or h.begins_with("feb"):
		return true
	# IPv4-mapped ::ffff:127.0.0.1 etc.
	if h.begins_with("::ffff:"):
		var mapped := h.substr(7)
		if _is_ipv4(mapped) and _ipv4_is_non_public(mapped):
			return true
	return false


static func _parse(url: String) -> Dictionary:
	var u := url.strip_edges()
	var tls := false
	if u.begins_with("https://"):
		tls = true
		u = u.substr(8)
	elif u.begins_with("http://"):
		tls = false
		u = u.substr(7)
	else:
		return {}
	var slash := u.find("/")
	var hostport := u if slash < 0 else u.substr(0, slash)
	var host := hostport
	var colon := hostport.rfind(":")
	if hostport.begins_with("["):
		var end := hostport.find("]")
		if end > 0:
			host = hostport.substr(1, end - 1)
		else:
			return {}
	elif colon > 0:
		host = hostport.substr(0, colon)
	return {"host": host, "tls": tls}


static func _bad(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "url": ""}
