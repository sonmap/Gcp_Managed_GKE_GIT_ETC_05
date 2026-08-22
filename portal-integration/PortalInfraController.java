package com.example.portal;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.util.StreamUtils;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Existing Java portal -> Cloud Run Colab adapter integration example.
 *
 * The portal owns request/approval workflow only. It does not run Terraform.
 * Approved JSON is forwarded to /preview or /deploy.
 *
 * Production: when Cloud Run requires authentication, add a Google-signed
 * ID token (audience = adapter URL) or place the service behind the approved
 * enterprise access layer.
 */
@RestController
@RequestMapping("/api/infra")
public class PortalInfraController {

    private final RestClient restClient;
    private final String adapterUrl;

    public PortalInfraController(RestClient.Builder builder,
                                 @Value("${infra.adapter.url}") String adapterUrl) {
        this.restClient = builder.build();
        this.adapterUrl = adapterUrl.replaceAll("/$", "");
    }

    @PostMapping(value = "/tasks/preview", consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> previewTask(HttpServletRequest request) throws IOException {
        return forwardJson(request, "/preview");
    }

    @PostMapping(value = "/tasks", consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> createTask(HttpServletRequest request) throws IOException {
        return forwardJson(request, "/deploy");
    }

    @GetMapping("/status")
    public ResponseEntity<String> status(@RequestParam String operation) {
        return restClient.get()
                .uri(adapterUrl + "/status?operation={operation}", operation)
                .exchange((req, response) -> {
                    String body = new String(response.getBody().readAllBytes(), StandardCharsets.UTF_8);
                    return ResponseEntity.status(response.getStatusCode())
                            .contentType(MediaType.APPLICATION_JSON)
                            .body(body);
                });
    }

    private ResponseEntity<String> forwardJson(HttpServletRequest request, String path)
            throws IOException {
        String json = StreamUtils.copyToString(request.getInputStream(), StandardCharsets.UTF_8);

        return restClient.post()
                .uri(adapterUrl + path)
                .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .body(json)
                .exchange((req, response) -> {
                    String body = new String(response.getBody().readAllBytes(), StandardCharsets.UTF_8);
                    return ResponseEntity.status(response.getStatusCode())
                            .contentType(MediaType.APPLICATION_JSON)
                            .body(body);
                });
    }
}
