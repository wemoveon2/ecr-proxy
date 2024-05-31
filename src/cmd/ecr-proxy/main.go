package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/aws/aws-sdk-go-v2/service/ecr/types"
	"github.com/pkg/errors"
	"go.uber.org/zap"
)

const (
	DefaultRegion = "us-east-1"
)

type (
	passwordMap    map[string]string
	passWordMapMap map[string]passwordMap

	ImageManifest struct {
		SchemaVersion int `json:"schemaVersion"`
		Config        struct {
			Digest string `json:"digest"`
		} `json:"config"`
		Layers []struct {
			MediaType string `json:"mediaType"`
			Digest    string `json:"digest"`
			Size      int    `json:"size"`
		} `json:"layers"`
	}
)

var (
	ecrAccount string
	region     string
	listenAddr string

	tlsCert string
	tlsKey  string
	tlsAddr string

	debug bool

	ecrClient *ecr.Client
	authData  *types.AuthorizationData

	TokenCheckInterval = time.Minute

	log *zap.Logger

	repos = map[string]passWordMapMap{
		"clarifai-web": tag,
	}
	tag = passWordMapMap{
		"123d8a9ae5db811525cf9af2b8e3ee660a830f47": users,
	}
	users = passwordMap{
		"username1": "password1",
		"username2": "password2",
	}
	blobHashToUsers = map[string]string{}
)

func init() {
	flag.StringVar(&listenAddr, "addr", ":8080", "listen address for HTTP proxy")
	flag.StringVar(&ecrAccount, "account", "", "aws account for the ECR registry")
	flag.StringVar(&region, "region", DefaultRegion, "region in which the ECR registry is located")
	flag.StringVar(&tlsAddr, "tls-addr", ":8443", "listen address for HTTPS proxy")
	flag.StringVar(&tlsCert, "tls-cert", tlsCert, "certificate file for TLS")
	flag.StringVar(&tlsKey, "tls-key", tlsKey, "key file for TLS")
	flag.BoolVar(&debug, "debug", false, "enable debug logging")
}

func main() {
	var err error

	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if debug {
		log, err = zap.NewDevelopment()
	} else {
		log, err = zap.NewProduction()
	}
	if err != nil {
		fmt.Println("failed to instantiate logger:", err)

		os.Exit(127)
	}

	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(region),
	)
	if err != nil {
		log.Fatal("failed to load AWS credential configuration", zap.Error(err))
	}

	if ecrAccount == "" {
		log.Fatal("ECR account must be specified")
	}

	ecrClient = ecr.NewFromConfig(cfg)

	authData, err = ensureToken(ctx, ecrClient, authData)
	if err != nil {
		log.Fatal("failed to get ECR authorization token", zap.Error(err))
	}

	go maintainToken(ctx, ecrClient)

	mux := http.NewServeMux()

	mux.Handle("/v2/", basicAuth(ecrClient)(&httputil.ReverseProxy{
		Director: func(req *http.Request) {
			if err := addAuthToken(req); err != nil {
				log.Error("failed to add auth token to request", zap.Error(err))
			}
		},
	}))

	mux.HandleFunc("/health", func(w http.ResponseWriter, req *http.Request) {
		if authData == nil || authData.ExpiresAt.Before(time.Now()) {
			w.WriteHeader(http.StatusServiceUnavailable)

			return
		}

		w.WriteHeader(http.StatusOK)
	})

	l, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatal("failed to listen on HTTP port", zap.String("addr", listenAddr), zap.Error(err))
	}

	go func() {
		<-ctx.Done()

		l.Close() //nolint:errcheck
	}()

	if tlsKey != "" && tlsCert != "" {
		secureListener, err := net.Listen("tcp", tlsAddr)
		if err != nil {
			log.Fatal("failed to listen on HTTPS port", zap.String("addr", tlsAddr), zap.Error(err))
		}

		go func() {
			<-ctx.Done()

			secureListener.Close() //nolint:errcheck
		}()

		go func() {
			if err = http.ServeTLS(secureListener, mux, tlsCert, tlsKey); err != nil {
				log.Fatal("HTTPS listener exited", zap.Error(err))
			}
		}()
	}

	err = http.Serve(l, mux)

	log.Fatal("HTTP listener exited", zap.Error(err))
}

func addAuthToken(req *http.Request) error {
	ecrEndpoint, err := url.Parse(aws.ToString(authData.ProxyEndpoint))
	if err != nil {
		return errors.Wrap(err, "failed to parse AWS ECR proxy endpoint")
	}

	req.URL.Scheme = ecrEndpoint.Scheme
	req.URL.Host = ecrEndpoint.Host
	req.Host = ecrEndpoint.Host

	req.Header.Set("Authorization", fmt.Sprintf("Basic %s", aws.ToString(authData.AuthorizationToken)))

	return nil
}

func maintainToken(ctx context.Context, ecrClient *ecr.Client) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(TokenCheckInterval):
		}

		newToken, err := ensureToken(ctx, ecrClient, authData)
		if err != nil {
			log.Error("failed to update token", zap.Error(err))

			continue
		}

		authData = newToken
	}
}

func ensureToken(ctx context.Context, ecrClient *ecr.Client, existingAuth *types.AuthorizationData) (*types.AuthorizationData, error) {
	if existingAuth != nil && existingAuth.ExpiresAt.After(time.Now().Add(time.Hour)) {
		return existingAuth, nil
	}

	resp, err := ecrClient.GetAuthorizationToken(ctx, &ecr.GetAuthorizationTokenInput{
		RegistryIds: []string{ecrAccount},
	})
	if err != nil {
		return nil, err
	}

	if len(resp.AuthorizationData) < 1 {
		return nil, fmt.Errorf("no authorization data found in AWS response")
	}

	return &(resp.AuthorizationData[0]), nil
}

func basicAuth(c *ecr.Client) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			log.Debug("basic auth", zap.String("path", r.URL.Path))
			repoName, tag, hash1, err := splitPath(r.URL.Path)
			log.Debug("split path", zap.String("repo", repoName), zap.String("tag", tag), zap.String("hash", hash1))
			if err != nil {
				http.Error(w, "invalid path format", http.StatusUnauthorized)
				return
			}
			if tag != "" {
				imgHash, err := GetImageHash(context.Background(), repoName, tag, c)
				if err != nil {
					http.Error(w, err.Error(), http.StatusUnauthorized)
					return
				}
				auth, ok := repos[repoName]
				if !ok {
					http.Error(w, "repository not found", http.StatusUnauthorized)
					return
				}
				tagAuth, ok := auth[tag]
				if !ok {
					http.Error(w, "tag not found", http.StatusUnauthorized)
					return
				}
				user, pass, ok := r.BasicAuth()
				if !ok || tagAuth[user] != pass {
					w.Header().Set("WWW-Authenticate", `Basic realm="Please enter your username and password"`)
					http.Error(w, "Unauthorized.", http.StatusUnauthorized)
					return
				}
				// allow future requests for this image to bypass the auth check
				blobHashToUsers[imgHash] = tagAuth[user]
			} else if hash1 != "" {
				_, pass1, ok1 := r.BasicAuth()
				if pass, ok := blobHashToUsers[hash1]; !ok || !ok1 || pass != pass1 {
					w.Header().Set("WWW-Authenticate", `Basic realm="Please enter your username and password"`)
					http.Error(w, "Unauthorized.", http.StatusUnauthorized)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

func splitPath(path string) (string, string, string, error) {
	const prefix = "/v2/"
	const manifestSuffix = "/manifests/"
	const hashSuffix = "sha256:"
	// Check if the path has the correct prefix and suffix
	if !strings.HasPrefix(path, prefix) {
		return "", "", "", fmt.Errorf("invalid path format")
	}
	// Remove the prefix
	trimmedPath := strings.TrimPrefix(path, prefix)
	var repository, tag string
	if strings.Contains(trimmedPath, manifestSuffix) {
		// Split the trimmed path into repository and tag parts for manifests
		parts := strings.Split(trimmedPath, manifestSuffix)
		if len(parts) != 2 {
			return "", "", "", fmt.Errorf("invalid path format")
		}
		repository = parts[0]
		tag = parts[1]
		if strings.Contains(tag, hashSuffix) {
			// Split the trimmed path into repository and tag parts for blobs
			parts := strings.Split(trimmedPath, hashSuffix)
			if len(parts) != 2 {
				return "", "", "", fmt.Errorf("invalid path format")
			}
			hash := parts[1]
			return repository, "", hash, nil
		}
		return repository, tag, "", nil
	} else {
		return "", "", "", fmt.Errorf("unknown path suffix")
	}
}

func GetImageHash(ctx context.Context, repositoryName, imageTag string, c *ecr.Client) (string, error) {
	input := &ecr.BatchGetImageInput{
		RepositoryName: aws.String(repositoryName),
		ImageIds: []types.ImageIdentifier{
			{
				ImageTag: aws.String(imageTag),
			},
		},
		AcceptedMediaTypes: []string{"application/vnd.docker.distribution.manifest.v2+json"},
	}
	result, err := c.BatchGetImage(ctx, input)
	if err != nil {
		return "", err
	}
	if len(result.Images) == 0 {
		return "", errors.New("image not found")
	}
	var imageManifest ImageManifest
	err = json.Unmarshal([]byte(*result.Images[0].ImageManifest), &imageManifest)
	if err != nil {
		return "", err
	}
	imageDigest := result.Images[0].ImageId.ImageDigest
	return *imageDigest, nil
}
