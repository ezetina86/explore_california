FROM nginx:stable-alpine3.20-perl
LABEL manteiner="Enrique Zetina <jenzetin@gmail.com>"

COPY ./website /website
COPY ./nginx.conf /etc/nginx/conf.d/default.conf

ENTRYPOINT ["nginx", "-g", "daemon off;"]
