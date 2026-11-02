package leita_cli

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

import "jm:http"
import "jm:selfupdate"

import "../human"
import "../licence"
import "../version"

LICENCE_ACTIVATE_URL      :: "https://mordaunt.dev/leita/activate"
LICENCE_ACTIVATE_ENV      :: "LEITA_ACTIVATE_URL"
LICENCE_ACTIVATE_TIMEOUT  :: 30 * time.Second
LICENCE_ACTIVATE_BODY_MAX :: 64 * 1024

// activate_licence is the only licence subcommand that sends anything. The
// response must verify before keep changes the line on disk, as with add.
@(private)
activate_licence :: proc(c: Licence_Context, key: string, w: io.Writer) -> int {
	if key == "" || len(key) > licence.RECEIPT_MAX || strings.index_any(key, " \t\r\n") >= 0 {
		say_error(
			"that is not a shop key: give the key from your receipt, without spaces, at most %d bytes",
			licence.RECEIPT_MAX,
		)
		return EXIT_ERROR
	}
	path := licence.path_beside(c.kept, context.temp_allocator)
	if path == "" {
		say_error("no folder to keep leita's data in")
		return EXIT_ERROR
	}
	line, problem := exchange_licence_key(c, key)
	if problem != "" {
		say_error("%s", problem)
		return EXIT_ERROR
	}
	l, err := licence.keep(path, line, c.key, context.temp_allocator)
	if err != .None {
		say_error("%s", licence.describe(err))
		return EXIT_ERROR
	}
	if licence.save_receipt(path, key) != .None {
		say_error(
			"the licence was saved, but its receipt key could not be kept; activate again when storage is writable",
		)
		return EXIT_ERROR
	}
	fmt.wprintfln(
		w,
		"added the licence: licensed to %s, %s; paid through %s",
		human.shown(l.licensee),
		TIER_TITLES[l.tier],
		l.paid_through,
	)
	return EXIT_OK
}

// exchange_licence_key uses the same bounded JSON contract as the window.
// The fixed writer refuses an oversized response while it arrives. A
// redirect is refused rather than sending a receipt key to another host.
@(private)
exchange_licence_key :: proc(c: Licence_Context, key: string) -> (line, problem: string) {
	endpoint := c.activate_url
	if endpoint == "" {
		endpoint = os.get_env(LICENCE_ACTIVATE_ENV, context.temp_allocator)
	}
	if endpoint == "" {
		endpoint = LICENCE_ACTIVATE_URL
	}
	Ask :: struct {
		key: string `json:"key"`,
	}
	request, jerr := json.marshal(Ask{key}, allocator = context.temp_allocator)
	if jerr != nil {
		return "", "the activation request could not be prepared"
	}
	body: selfupdate.Fixed(LICENCE_ACTIVATE_BODY_MAX)
	response, err := http.stream(
		"POST",
		endpoint,
		selfupdate.fixed_writer(&body),
		{
			headers = {"Content-Type: application/json", "Accept: application/json"},
			body = string(request),
			timeout = c.activate_timeout if c.activate_timeout > 0 else LICENCE_ACTIVATE_TIMEOUT,
			no_follow = true,
			user_agent = "leita/" + version.VERSION,
		},
	)
	switch {
	case err == .No_Library:
		return "",
			"activation needs libcurl; install it or use leita licence add with the licence line from your receipt"
	case err == .Timed_Out:
		return "", "the activation server did not answer in time; try again later"
	case err == .Write_Failed || err == .Too_Large:
		return "",
			"the activation server returned a response larger than 64 KiB; no licence was added"
	case err != .None:
		return "",
			"the activation server could not be reached; check your connection and try again"
	}
	return licence_activation_response(response.status, selfupdate.fixed_string(&body), key)
}

// licence_activation_response grants only a 200 JSON licence object. The
// caller still verifies its signature. Server diagnostics are one bounded
// line, with a reflected receipt key removed before anything is printed.
@(private)
licence_activation_response :: proc(status: int, body, key: string) -> (line, problem: string) {
	if status == 200 {
		Granted :: struct {
			licence: string `json:"licence"`,
		}
		granted: Granted
		err := json.unmarshal_string(body, &granted, .JSON, allocator = context.temp_allocator)
		if err != nil || granted.licence == "" {
			return "", "the activation server returned no licence; try again later"
		}
		return granted.licence, ""
	}
	if status >= 400 && status < 500 {
		Fault :: struct {
			message: string `json:"message"`,
		}
		fault: Fault
		err := json.unmarshal_string(body, &fault, .JSON, allocator = context.temp_allocator)
		if err == nil && fault.message != "" {
			message, _ := strings.replace_all(
				fault.message,
				key,
				"[redacted]",
				context.temp_allocator,
			)
			if end := strings.index_any(message, "\r\n"); end >= 0 {
				message = message[:end]
			}
			if message != "" {
				return "", fmt.tprintf(
					"activation refused (HTTP %d): %s",
					status,
					message[:min(len(message), 200)],
				)
			}
		}
		switch status {
		case 404:
			return "",
				"activation refused (HTTP 404): no licence was found for this key; check the receipt or refund status"
		case 409:
			return "",
				"activation refused (HTTP 409): the order has not settled yet; try again later"
		case 423:
			return "",
				"activation refused (HTTP 423): this order is waiting for a licence decision"
		}
		return "", fmt.tprintf(
			"activation refused (HTTP %d): the server did not accept the key",
			status,
		)
	}
	if status >= 300 && status < 400 {
		return "", fmt.tprintf(
			"activation refused a redirect (HTTP %d); check the activation address",
			status,
		)
	}
	return "", fmt.tprintf(
		"the activation server could not complete the request (HTTP %d); try again later",
		status,
	)
}
