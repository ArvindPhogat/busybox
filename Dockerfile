FROM node

WORKDIR /my

COPY . .

RUN npm install

EXPOSE 3000

CMD ["npm", "start"]

