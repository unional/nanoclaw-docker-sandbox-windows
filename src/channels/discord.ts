import fs from 'fs';
import path from 'path';

import {
  Client,
  Events,
  GatewayIntentBits,
  Message,
  TextChannel,
} from 'discord.js';
import { ProxyAgent } from 'undici';

import { ASSISTANT_NAME, GROUPS_DIR, TRIGGER_PATTERN } from '../config.js';
import { readEnvFile, readEnvFileByPrefix } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';

// Create undici ProxyAgent if running through a sandbox proxy
const proxyUrl =
  process.env.https_proxy ||
  process.env.HTTPS_PROXY ||
  process.env.http_proxy ||
  process.env.HTTP_PROXY;
const discordProxyAgent = proxyUrl
  ? new ProxyAgent({ uri: proxyUrl })
  : undefined;
import {
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

export interface DiscordChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
}

export class DiscordChannel implements Channel {
  name: string;

  private client: Client | null = null;
  private opts: DiscordChannelOpts;
  private botToken: string;
  private botName: string;

  constructor(botName: string, botToken: string, opts: DiscordChannelOpts) {
    this.botName = botName;
    this.botToken = botToken;
    this.opts = opts;
    this.name = botName === 'default' ? 'discord' : `discord_${botName}`;
  }

  private makeJid(channelId: string): string {
    return this.botName === 'default'
      ? `dc:${channelId}`
      : `dc:${this.botName}:${channelId}`;
  }

  private extractChannelId(jid: string): string {
    // dc:channelId  →  channelId
    // dc:botName:channelId  →  channelId
    const parts = jid.slice(3).split(':');
    return parts[parts.length - 1];
  }

  async connect(): Promise<void> {
    this.client = new Client({
      intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
        GatewayIntentBits.DirectMessages,
      ],
      ...(discordProxyAgent
        ? { rest: { agent: discordProxyAgent as never } }
        : {}),
    });

    this.client.on(Events.MessageCreate, async (message: Message) => {
      // Ignore bot messages (including own)
      if (message.author.bot) return;

      const channelId = message.channelId;
      const chatJid = this.makeJid(channelId);
      let content = message.content;
      const timestamp = message.createdAt.toISOString();
      const senderName =
        message.member?.displayName ||
        message.author.displayName ||
        message.author.username;
      const sender = message.author.id;
      const msgId = message.id;

      // Determine chat name
      let chatName: string;
      if (message.guild) {
        const textChannel = message.channel as TextChannel;
        chatName = `${message.guild.name} #${textChannel.name}`;
      } else {
        chatName = senderName;
      }

      // Translate Discord @bot mentions into TRIGGER_PATTERN format.
      // Discord mentions look like <@botUserId> — these won't match
      // TRIGGER_PATTERN (e.g., ^@Andy\b), so we prepend the trigger
      // when the bot is @mentioned.
      if (this.client?.user) {
        const botId = this.client.user.id;
        const isBotMentioned =
          message.mentions.users.has(botId) ||
          content.includes(`<@${botId}>`) ||
          content.includes(`<@!${botId}>`);

        if (isBotMentioned) {
          // Strip the <@botId> mention to avoid visual clutter
          content = content
            .replace(new RegExp(`<@!?${botId}>`, 'g'), '')
            .trim();
          // Prepend trigger if not already present
          if (!TRIGGER_PATTERN.test(content)) {
            content = `@${ASSISTANT_NAME} ${content}`;
          }
        }
      }

      // Handle attachments — PDFs are downloaded after group check; others get placeholders
      const pdfAttachments: Array<{ name: string; url: string }> = [];
      if (message.attachments.size > 0) {
        const descriptions = [...message.attachments.values()].flatMap(
          (att) => {
            const contentType = att.contentType || '';
            if (
              contentType === 'application/pdf' ||
              att.name?.toLowerCase().endsWith('.pdf')
            ) {
              pdfAttachments.push({
                name: att.name || `doc-${Date.now()}.pdf`,
                url: att.url,
              });
              return [];
            }
            if (contentType.startsWith('image/')) {
              return [`[Image: ${att.name || 'image'}]`];
            } else if (contentType.startsWith('video/')) {
              return [`[Video: ${att.name || 'video'}]`];
            } else if (contentType.startsWith('audio/')) {
              return [`[Audio: ${att.name || 'audio'}]`];
            } else {
              return [`[File: ${att.name || 'file'}]`];
            }
          },
        );
        if (descriptions.length > 0) {
          content = content
            ? `${content}\n${descriptions.join('\n')}`
            : descriptions.join('\n');
        }
      }

      // Handle reply context — include who the user is replying to
      if (message.reference?.messageId) {
        try {
          const repliedTo = await message.channel.messages.fetch(
            message.reference.messageId,
          );
          const replyAuthor =
            repliedTo.member?.displayName ||
            repliedTo.author.displayName ||
            repliedTo.author.username;
          content = `[Reply to ${replyAuthor}] ${content}`;
        } catch {
          // Referenced message may have been deleted
        }
      }

      // Store chat metadata for discovery
      const isGroup = message.guild !== null;
      this.opts.onChatMetadata(
        chatJid,
        timestamp,
        chatName,
        'discord',
        isGroup,
      );

      // Only deliver full message for registered groups
      const group = this.opts.registeredGroups()[chatJid];
      if (!group) {
        logger.debug(
          { chatJid, chatName },
          'Message from unregistered Discord channel',
        );
        return;
      }

      // Download PDF attachments for registered groups
      for (const pdfAtt of pdfAttachments) {
        try {
          const res = await fetch(
            pdfAtt.url,
            discordProxyAgent
              ? ({ dispatcher: discordProxyAgent } as never)
              : {},
          );
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const buffer = Buffer.from(await res.arrayBuffer());
          const groupDir = path.join(GROUPS_DIR, group.folder);
          const attachDir = path.join(groupDir, 'attachments');
          fs.mkdirSync(attachDir, { recursive: true });
          const filename = path.basename(pdfAtt.name);
          fs.writeFileSync(path.join(attachDir, filename), buffer);
          const sizeKB = Math.round(buffer.length / 1024);
          const pdfRef = `[PDF: attachments/${filename} (${sizeKB}KB)]\nUse: pdf-reader extract attachments/${filename}`;
          content = content ? `${content}\n${pdfRef}` : pdfRef;
          logger.info(
            { jid: chatJid, filename },
            'Downloaded Discord PDF attachment',
          );
        } catch (err) {
          logger.warn(
            { err, jid: chatJid },
            'Failed to download Discord PDF attachment',
          );
        }
      }

      // Deliver message — startMessageLoop() will pick it up
      this.opts.onMessage(chatJid, {
        id: msgId,
        chat_jid: chatJid,
        sender,
        sender_name: senderName,
        content,
        timestamp,
        is_from_me: false,
      });

      logger.info(
        { chatJid, chatName, sender: senderName },
        'Discord message stored',
      );
    });

    // Handle errors gracefully
    this.client.on(Events.Error, (err) => {
      logger.error({ err: err.message }, 'Discord client error');
    });

    return new Promise<void>((resolve, reject) => {
      this.client!.once(Events.ClientReady, (readyClient) => {
        logger.info(
          { username: readyClient.user.tag, id: readyClient.user.id },
          'Discord bot connected',
        );
        console.log(`\n  Discord bot: ${readyClient.user.tag}`);
        console.log(
          `  Use /chatid command or check channel IDs in Discord settings\n`,
        );
        resolve();
      });

      this.client!.login(this.botToken).catch(reject);
    });
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    if (!this.client) {
      logger.warn('Discord client not initialized');
      return;
    }

    try {
      const channelId = this.extractChannelId(jid);
      const channel = await this.client.channels.fetch(channelId);

      if (!channel || !('send' in channel)) {
        logger.warn({ jid }, 'Discord channel not found or not text-based');
        return;
      }

      const textChannel = channel as TextChannel;

      // Discord has a 2000 character limit per message — split if needed
      const MAX_LENGTH = 2000;
      if (text.length <= MAX_LENGTH) {
        await textChannel.send(text);
      } else {
        for (let i = 0; i < text.length; i += MAX_LENGTH) {
          await textChannel.send(text.slice(i, i + MAX_LENGTH));
        }
      }
      logger.info({ jid, length: text.length }, 'Discord message sent');
    } catch (err) {
      logger.error({ jid, err }, 'Failed to send Discord message');
    }
  }

  isConnected(): boolean {
    return this.client !== null && this.client.isReady();
  }

  ownsJid(jid: string): boolean {
    if (!jid.startsWith('dc:')) return false;
    const rest = jid.slice(3);
    if (this.botName === 'default') {
      // Claim legacy numeric JIDs (no colon = no botName segment)
      return !rest.includes(':');
    }
    return rest.startsWith(`${this.botName}:`);
  }

  async disconnect(): Promise<void> {
    if (this.client) {
      this.client.destroy();
      this.client = null;
      logger.info('Discord bot stopped');
    }
  }

  async setTyping(jid: string, isTyping: boolean): Promise<void> {
    if (!this.client || !isTyping) return;
    try {
      const channelId = this.extractChannelId(jid);
      const channel = await this.client.channels.fetch(channelId);
      if (channel && 'sendTyping' in channel) {
        await (channel as TextChannel).sendTyping();
      }
    } catch (err) {
      logger.debug({ jid, err }, 'Failed to send Discord typing indicator');
    }
  }
}

// Discover all configured bot tokens at module load time
const _defaultEnv = readEnvFile(['DISCORD_BOT_TOKEN']);
const _namedBotEnv = readEnvFileByPrefix('DISCORD_BOT_TOKEN_');
const _allDiscordEnv: Record<string, string> = {
  ..._defaultEnv,
  ...(_namedBotEnv as Record<string, string>),
};
// process.env takes precedence over .env file
for (const key of Object.keys(_allDiscordEnv)) {
  if (process.env[key]) _allDiscordEnv[key] = process.env[key]!;
}

const TOKEN_PREFIX = 'DISCORD_BOT_TOKEN_';

// Register default bot (backward-compatible: DISCORD_BOT_TOKEN)
const _defaultToken = _allDiscordEnv.DISCORD_BOT_TOKEN;
if (_defaultToken) {
  registerChannel('discord', (opts: ChannelOpts) => {
    return new DiscordChannel('default', _defaultToken, opts);
  });
}

// Register named bots (DISCORD_BOT_TOKEN_<NAME>)
for (const [key, token] of Object.entries(_allDiscordEnv)) {
  if (!key.startsWith(TOKEN_PREFIX) || !token) continue;
  const botName = key.slice(TOKEN_PREFIX.length).toLowerCase();
  registerChannel(`discord_${botName}`, (opts: ChannelOpts) => {
    return new DiscordChannel(botName, token, opts);
  });
}

if (!_defaultToken && Object.keys(_namedBotEnv).length === 0) {
  logger.warn(
    'Discord: no DISCORD_BOT_TOKEN or DISCORD_BOT_TOKEN_* configured',
  );
}
