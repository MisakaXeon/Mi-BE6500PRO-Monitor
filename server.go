package main

import (
	"fmt"
	"net"
	"net/http"
	"time"
)

const acceptWakeInterval = 15 * time.Second

type deadlineListener interface {
	net.Listener
	SetDeadline(time.Time) error
}

// wakeListener periodically retries Accept so a missed edge-triggered wakeup
// cannot leave the embedded router's HTTP listener asleep indefinitely.
type wakeListener struct {
	listener deadlineListener
	interval time.Duration
}

func (l *wakeListener) Accept() (net.Conn, error) {
	for {
		if err := l.listener.SetDeadline(time.Now().Add(l.interval)); err != nil {
			return nil, err
		}
		conn, err := l.listener.Accept()
		if err == nil {
			return conn, nil
		}
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			continue
		}
		return nil, err
	}
}

func (l *wakeListener) Close() error   { return l.listener.Close() }
func (l *wakeListener) Addr() net.Addr { return l.listener.Addr() }

func newHTTPServer(address string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
}

func listenAndServe(server *http.Server) error {
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return err
	}
	deadlineCapable, ok := listener.(deadlineListener)
	if !ok {
		_ = listener.Close()
		return fmt.Errorf("listener %T does not support deadlines", listener)
	}
	return server.Serve(&wakeListener{listener: deadlineCapable, interval: acceptWakeInterval})
}
