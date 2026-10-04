// Caddy entry point for the anycable variant; see README.md.
package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddyserver/caddy/v2/modules/standard"
	_ "github.com/dunglas/caddy-cbrotli"
	_ "github.com/dunglas/mercure/caddy"
	_ "github.com/evilmartians/caddy_anycable"
)

func main() {
	caddycmd.Main()
}
