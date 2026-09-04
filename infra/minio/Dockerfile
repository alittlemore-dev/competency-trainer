FROM minio/minio:RELEASE.2025-09-07T16-13-09Z

COPY infra/minio/entrypoint.sh /usr/local/bin/competency-trainer-minio-entrypoint

RUN echo "minio:x:10002:10002:MinIO:/data:/sbin/nologin" >> /etc/passwd \
 && echo "minio:x:10002:" >> /etc/group \
 && mkdir -p /data \
 && chown -R 10002:10002 /data \
 && chmod 755 /usr/local/bin/competency-trainer-minio-entrypoint

USER 10002:10002
ENTRYPOINT ["competency-trainer-minio-entrypoint"]
CMD ["server", "/data", "--console-address", ":9001"]
