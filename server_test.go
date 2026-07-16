package main

import (
	"errors"
	"net"
	"net/http"
	"testing"
	"time"
)

type timeoutError struct{}

func (timeoutError) Error() string   { return "accept timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

type scriptedDeadlineListener struct {
	acceptCalls   int
	deadlineCalls int
	closed        bool
	addr          net.Addr
	conn          net.Conn
	terminalErr   error
}

func (l *scriptedDeadlineListener) Accept() (net.Conn, error) {
	l.acceptCalls++
	if l.acceptCalls == 1 {
		return nil, timeoutError{}
	}
	if l.terminalErr != nil {
		return nil, l.terminalErr
	}
	return l.conn, nil
}

func (l *scriptedDeadlineListener) Close() error {
	l.closed = true
	return nil
}
func (l *scriptedDeadlineListener) Addr() net.Addr { return l.addr }
func (l *scriptedDeadlineListener) SetDeadline(time.Time) error {
	l.deadlineCalls++
	return nil
}

func TestWakeListenerProxiesCloseAndAddr(t *testing.T) {
	wantAddr := &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9898}
	scripted := &scriptedDeadlineListener{addr: wantAddr}
	listener := &wakeListener{listener: scripted, interval: time.Second}

	if listener.Addr() != wantAddr {
		t.Fatal("Addr did not proxy to the wrapped listener")
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if !scripted.closed {
		t.Fatal("Close did not close the wrapped listener")
	}
}

func TestWakeListenerRetriesTimedOutAccept(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	scripted := &scriptedDeadlineListener{conn: serverConn}
	listener := &wakeListener{listener: scripted, interval: time.Second}

	got, err := listener.Accept()
	if err != nil {
		t.Fatalf("Accept returned error: %v", err)
	}
	if got != serverConn {
		t.Fatal("Accept returned the wrong connection")
	}
	if scripted.acceptCalls != 2 || scripted.deadlineCalls != 2 {
		t.Fatalf("calls = accept:%d deadline:%d, want 2 and 2", scripted.acceptCalls, scripted.deadlineCalls)
	}
}

func TestWakeListenerReturnsNonTimeoutError(t *testing.T) {
	want := errors.New("listener closed")
	scripted := &scriptedDeadlineListener{terminalErr: want}
	listener := &wakeListener{listener: scripted, interval: time.Second}

	_, err := listener.Accept()
	if !errors.Is(err, want) {
		t.Fatalf("Accept error = %v, want %v", err, want)
	}
}

func TestNewHTTPServerUsesDefensiveTimeouts(t *testing.T) {
	server := newHTTPServer("127.0.0.1:9898", http.NewServeMux())

	if server.ReadHeaderTimeout <= 0 || server.ReadTimeout <= 0 || server.WriteTimeout <= 0 || server.IdleTimeout <= 0 {
		t.Fatalf("server timeouts must be positive: %+v", server)
	}
	if server.MaxHeaderBytes <= 0 {
		t.Fatalf("MaxHeaderBytes = %d, want a positive limit", server.MaxHeaderBytes)
	}
}
