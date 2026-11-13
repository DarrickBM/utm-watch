// utmwatch-net embeds a userspace Tailscale node (tsnet) so UTM Watch can
// reach a fleet hub on another LAN without the user installing Tailscale.
//
// Client mode (always on): a loopback proxy that dials through the tailnet.
// The one port speaks both HTTP proxy (CONNECT and plain requests) and SOCKS5.
//
// Hub mode (-forward): additionally accepts connections on a tailnet port and
// forwards them to a local address.
//
// All state lives under -dir. Nothing is read from or written to the system
// Tailscale's locations, and no TUN device or system extension is used.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tailscale.com/net/socks5"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

type forwardRule struct {
	tailnetPort string // port on this node's tailnet address
	local       string // host:port on this machine
}

type forwardFlag []forwardRule

func (f *forwardFlag) String() string { return fmt.Sprint(*f) }
func (f *forwardFlag) Set(v string) error {
	port, local, ok := strings.Cut(v, "=")
	if !ok || port == "" || local == "" {
		return errors.New("want TAILNET_PORT=HOST:PORT, for example 8787=127.0.0.1:8787")
	}
	if _, _, err := net.SplitHostPort(local); err != nil {
		return err
	}
	*f = append(*f, forwardRule{port, local})
	return nil
}

// event is one line of machine-readable status on stdout, for the parent app.
type event struct {
	Event    string   `json:"event"`
	Hostname string   `json:"hostname,omitempty"`
	DNSName  string   `json:"dnsName,omitempty"`
	IPs      []string `json:"ips,omitempty"`
	Proxy    string   `json:"proxy,omitempty"`
	Forwards []string `json:"forwards,omitempty"`
	Tailnet  string   `json:"tailnet,omitempty"`
	Expiry   string   `json:"keyExpiry,omitempty"`
	Error    string   `json:"error,omitempty"`
	URL      string   `json:"url,omitempty"`
}

func emit(e event) {
	b, _ := json.Marshal(e)
	fmt.Println(string(b))
}

func main() {
	var (
		dir        = flag.String("dir", "", "state directory (required); created if missing")
		hostname   = flag.String("hostname", "", "node name on the tailnet (default: this machine's host name with a utmwatch- prefix)")
		proxyAddr  = flag.String("proxy", "127.0.0.1:0", "loopback address for the HTTP+SOCKS5 proxy; port 0 picks a free one")
		keyFile    = flag.String("authkey-file", "", "file holding the Tailscale auth key; '-' reads one line from stdin. TS_AUTHKEY also works. Only needed for the first join")
		ephemeral  = flag.Bool("ephemeral", false, "register as an ephemeral node (removed from the tailnet soon after it goes offline)")
		tags       = flag.String("tags", "", "comma-separated tags to advertise, for example tag:utmwatch")
		joinWait   = flag.Duration("join-timeout", 60*time.Second, "how long to wait for the node to join")
		verbose    = flag.Bool("verbose", false, "print Tailscale backend logs to stderr")
		uploadLogs = flag.Bool("upload-logs", false, "let the node upload its logs to log.tailscale.com (tsnet's default; off here)")
		withParent = flag.Bool("exit-with-parent", false, "stop when stdin reaches end of file or the parent process goes away; the app holds stdin open for as long as it runs")
		forwards   forwardFlag
	)
	flag.Var(&forwards, "forward", "hub mode: TAILNET_PORT=HOST:PORT, repeatable")
	flag.Parse()
	log.SetFlags(log.Ltime)
	log.SetOutput(os.Stderr)

	if *dir == "" {
		log.Fatal("-dir is required")
	}
	abs, err := filepath.Abs(*dir)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(abs, 0o700); err != nil {
		log.Fatal(err)
	}
	if host, _, err := net.SplitHostPort(*proxyAddr); err != nil || !isLoopback(host) {
		log.Fatalf("-proxy must be a loopback address, got %q", *proxyAddr)
	}
	if !*uploadLogs {
		// Must be set before tsnet starts; it reads this through envknob.
		os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	}

	authKey, err := readAuthKey(*keyFile)
	if err != nil {
		log.Fatal(err)
	}
	// Keep the key out of the environment of anything we might spawn.
	os.Unsetenv("TS_AUTHKEY")
	os.Unsetenv("TS_AUTH_KEY")

	if *hostname == "" {
		h, _ := os.Hostname()
		h, _, _ = strings.Cut(h, ".")
		*hostname = "utmwatch-" + strings.ToLower(h)
	}

	srv := &tsnet.Server{
		Dir:       abs,
		Hostname:  *hostname,
		AuthKey:   authKey,
		Ephemeral: *ephemeral,
		UserLogf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			// Without a usable key tsnet falls back to interactive login and
			// prints a URL. The app must never open it; report and let the
			// parent decide.
			if i := strings.Index(msg, "https://login.tailscale.com/"); i >= 0 {
				emit(event{Event: "needs-login", URL: strings.TrimSpace(msg[i:])})
			}
			log.Print("tsnet: ", msg)
		},
	}
	if *verbose {
		srv.Logf = func(format string, args ...any) { log.Printf("ts: "+format, args...) }
	}
	if *tags != "" {
		srv.AdvertiseTags = strings.Split(*tags, ",")
	}
	defer srv.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *withParent {
		ctx = watchParent(ctx)
	}

	started := time.Now()
	upCtx, cancel := context.WithTimeout(ctx, *joinWait)
	st, err := srv.Up(upCtx)
	cancel()
	if err != nil {
		emit(event{Event: "error", Error: "join: " + err.Error()})
		os.Exit(1)
	}
	log.Printf("joined in %s", time.Since(started).Round(time.Millisecond))

	// Hub mode: tailnet port -> local address.
	var fwdDesc []string
	for _, r := range forwards {
		ln, err := srv.Listen("tcp", ":"+r.tailnetPort)
		if err != nil {
			emit(event{Event: "error", Error: "forward " + r.tailnetPort + ": " + err.Error()})
			os.Exit(1)
		}
		fwdDesc = append(fwdDesc, r.tailnetPort+"->"+r.local)
		go serveForward(ln, r.local)
	}

	// Client mode: loopback proxy -> tailnet.
	ln, err := net.Listen("tcp", *proxyAddr)
	if err != nil {
		emit(event{Event: "error", Error: "proxy: " + err.Error()})
		os.Exit(1)
	}
	go serveProxy(ln, srv)

	ready := event{
		Event:    "ready",
		Hostname: *hostname,
		Proxy:    ln.Addr().String(),
		Forwards: fwdDesc,
	}
	for _, ip := range st.TailscaleIPs {
		ready.IPs = append(ready.IPs, ip.String())
	}
	if st.Self != nil {
		ready.DNSName = strings.TrimSuffix(st.Self.DNSName, ".")
		if st.Self.KeyExpiry != nil {
			ready.Expiry = st.Self.KeyExpiry.UTC().Format(time.RFC3339)
		} else {
			ready.Expiry = "never"
		}
	}
	if st.CurrentTailnet != nil {
		ready.Tailnet = st.CurrentTailnet.Name
	}
	emit(ready)

	<-ctx.Done()
	emit(event{Event: "stopping"})
}

// watchParent returns a context that ends when the parent app is gone, however it ended: a crash or a forced kill
// skips the app's own clean-up, and the helper would otherwise run on forever. The app holds the write end of a pipe
// on our stdin, which the system closes when the app exits, so end of file is the signal. A changed parent process
// ID (re-parented to launchd) is a second check in case stdin is not that pipe.
func watchParent(parent context.Context) context.Context {
	ctx, cancel := context.WithCancel(parent)
	go func() {
		io.Copy(io.Discard, os.Stdin)
		log.Printf("stdin closed: the parent app is gone")
		cancel()
	}()
	ppid := os.Getppid()
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if os.Getppid() != ppid {
					log.Printf("parent process %d is gone", ppid)
					cancel()
					return
				}
			}
		}
	}()
	return ctx
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func readAuthKey(path string) (string, error) {
	switch path {
	case "":
		if k := os.Getenv("TS_AUTHKEY"); k != "" {
			return k, nil
		}
		return os.Getenv("TS_AUTH_KEY"), nil
	case "-":
		line, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && line == "" {
			return "", fmt.Errorf("reading auth key from stdin: %w", err)
		}
		return strings.TrimSpace(line), nil
	default:
		b, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(b)), nil
	}
}

func serveForward(ln net.Listener, local string) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			up, err := net.DialTimeout("tcp", local, 5*time.Second)
			if err != nil {
				log.Printf("forward: %s: %v", local, err)
				return
			}
			defer up.Close()
			pipe(c, up)
		}()
	}
}

// serveProxy accepts on the loopback listener and routes each connection by
// its first byte: 0x05 is SOCKS5, anything else is treated as HTTP.
func serveProxy(ln net.Listener, srv *tsnet.Server) {
	socksLn := newChanListener(ln.Addr())
	httpLn := newChanListener(ln.Addr())

	ss := &socks5.Server{
		Logf:   func(string, ...any) {},
		Dialer: srv.Dial,
	}
	go ss.Serve(socksLn)

	rp := &httputil.ReverseProxy{
		Director: func(*http.Request) {}, // forward-proxy requests already carry an absolute URL
		Transport: &http.Transport{
			DialContext:           srv.Dial,
			MaxIdleConnsPerHost:   4,
			IdleConnTimeout:       60 * time.Second,
			ResponseHeaderTimeout: 60 * time.Second,
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "utmwatch-net: "+err.Error(), http.StatusBadGateway)
		},
	}
	hs := &http.Server{
		ReadHeaderTimeout: 10 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case r.URL.Host == diagHost:
				handleDiag(w, r, srv)
			case r.Method == http.MethodConnect:
				handleConnect(w, r, srv)
			case r.URL.IsAbs():
				r.RequestURI = ""
				rp.ServeHTTP(w, r)
			default:
				http.Error(w, "utmwatch-net is a proxy; send an absolute URL or CONNECT", http.StatusBadRequest)
			}
		}),
	}
	go hs.Serve(httpLn)

	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			br := bufio.NewReader(c)
			c.SetReadDeadline(time.Now().Add(10 * time.Second))
			first, err := br.Peek(1)
			c.SetReadDeadline(time.Time{})
			if err != nil {
				c.Close()
				return
			}
			pc := &peekedConn{Conn: c, r: br}
			if first[0] == 0x05 {
				socksLn.ch <- pc
			} else {
				httpLn.ch <- pc
			}
		}()
	}
}

// diagHost is a name the proxy answers itself: http://utmwatch.diag/check?ip=<tailnet address> says whether this
// node is connected to a relay and whether that peer answers, so the app can tell the user which side is at fault.
const diagHost = "utmwatch.diag"

type diagReply struct {
	Relay     string   `json:"relay"`               // this node's home relay region; empty = no relay connection
	Health    []string `json:"health,omitempty"`    // problems the node itself reports
	PeerKnown bool     `json:"peerKnown"`           // the address belongs to a device on this network
	PeerOn    bool     `json:"peerOnline"`          // the coordination server sees that device connected
	PingVia   string   `json:"pingVia,omitempty"`   // "direct" or "relay:<region>"
	PingMs    float64  `json:"pingMs,omitempty"`
	PingError string   `json:"pingError,omitempty"`
}

func handleDiag(w http.ResponseWriter, r *http.Request, srv *tsnet.Server) {
	var out diagReply
	defer func() {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
	}()
	lc, err := srv.LocalClient()
	if err != nil {
		out.PingError = err.Error()
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	ip, ipErr := netip.ParseAddr(r.URL.Query().Get("ip"))
	if st, err := lc.Status(ctx); err == nil {
		out.Health = st.Health
		if st.Self != nil {
			out.Relay = st.Self.Relay
		}
		for _, p := range st.Peer {
			for _, a := range p.TailscaleIPs {
				if ipErr == nil && a == ip {
					out.PeerKnown, out.PeerOn = true, p.Online
				}
			}
		}
	}
	if ipErr != nil {
		out.PingError = "no address given"
		return
	}
	pr, err := lc.Ping(ctx, ip, tailcfg.PingDisco)
	switch {
	case err != nil:
		out.PingError = err.Error()
	case pr.Err != "":
		out.PingError = pr.Err
	default:
		out.PingMs = pr.LatencySeconds * 1000
		if pr.Endpoint != "" {
			out.PingVia = "direct"
		} else {
			out.PingVia = "relay:" + pr.DERPRegionCode
		}
	}
}

func handleConnect(w http.ResponseWriter, r *http.Request, srv *tsnet.Server) {
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	up, err := srv.Dial(ctx, "tcp", r.Host)
	cancel()
	if err != nil {
		http.Error(w, "utmwatch-net: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer up.Close()
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack unsupported", http.StatusInternalServerError)
		return
	}
	c, buf, err := hj.Hijack()
	if err != nil {
		return
	}
	defer c.Close()
	io.WriteString(c, "HTTP/1.1 200 Connection Established\r\n\r\n")
	// Bytes the client sent right after the CONNECT header are in buf.
	pipe(&peekedConn{Conn: c, r: buf.Reader}, up)
}

func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
}

// peekedConn is a net.Conn whose first bytes were already buffered.
type peekedConn struct {
	net.Conn
	r *bufio.Reader
}

func (p *peekedConn) Read(b []byte) (int, error) { return p.r.Read(b) }
func (p *peekedConn) CloseWrite() error {
	if cw, ok := p.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return p.Conn.Close()
}

// chanListener hands pre-accepted connections to an http or socks server.
type chanListener struct {
	ch   chan net.Conn
	addr net.Addr
}

func newChanListener(a net.Addr) *chanListener {
	return &chanListener{ch: make(chan net.Conn), addr: a}
}
func (l *chanListener) Accept() (net.Conn, error) {
	c, ok := <-l.ch
	if !ok {
		return nil, net.ErrClosed
	}
	return c, nil
}
func (l *chanListener) Close() error   { return nil }
func (l *chanListener) Addr() net.Addr { return l.addr }
