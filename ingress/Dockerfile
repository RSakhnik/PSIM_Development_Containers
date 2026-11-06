FROM nginx:1.27-alpine
RUN apk add --no-cache iptables
COPY entrypoint.sh /pilot-entrypoint.sh
RUN chmod 0555 /pilot-entrypoint.sh
ENTRYPOINT ["/pilot-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
