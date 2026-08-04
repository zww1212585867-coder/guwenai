FROM node:22-alpine

WORKDIR /app

# 先装依赖，利用缓存
COPY package.json ./
RUN npm install --omit=dev

COPY . .

# 持久化数据卷挂载到 /app/data
RUN npm run seed

EXPOSE 3000

CMD ["node", "server/index.js"]
