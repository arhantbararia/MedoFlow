-- CreateEnum
CREATE TYPE "VoiceCallStatus" AS ENUM ('IN_PROGRESS', 'COMPLETED', 'FAILED', 'TRANSFERRED', 'ABANDONED');

-- CreateEnum
CREATE TYPE "VoiceCallChannel" AS ENUM ('BROWSER', 'PHONE');

-- CreateEnum
CREATE TYPE "VoiceCallOutcome" AS ENUM ('APPOINTMENT_BOOKED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED', 'MESSAGE_TAKEN', 'REFILL_REQUESTED', 'INFO_PROVIDED', 'TRANSFERRED_TO_HUMAN', 'NO_ACTION');

-- CreateEnum
CREATE TYPE "VoicePersona" AS ENUM ('WARM', 'PROFESSIONAL', 'UPBEAT');

-- CreateTable
CREATE TABLE "VoiceAgentConfig" (
    "id" TEXT NOT NULL,
    "clinicId" TEXT NOT NULL,
    "enabled" BOOLEAN NOT NULL DEFAULT false,
    "greeting" TEXT NOT NULL DEFAULT 'Hi! Thanks for calling. I''m an AI assistant who can help with booking, rescheduling, and answering questions about the clinic. How can I help you today?',
    "persona" "VoicePersona" NOT NULL DEFAULT 'WARM',
    "voice" TEXT NOT NULL DEFAULT 'alloy',
    "businessHours" JSONB,
    "afterHoursMessage" TEXT NOT NULL DEFAULT 'We''re closed right now. I can take a message and a staff member will get back to you on the next business day. Or, would you like to book online?',
    "escalationPhone" TEXT,
    "capabilities" JSONB NOT NULL DEFAULT '{"book":true,"reschedule":true,"cancel":true,"refill":true,"messages":true,"transfer":true,"info":true}',
    "systemPromptExtra" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "VoiceAgentConfig_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "VoiceCall" (
    "id" TEXT NOT NULL,
    "clinicId" TEXT NOT NULL,
    "channel" "VoiceCallChannel" NOT NULL DEFAULT 'BROWSER',
    "status" "VoiceCallStatus" NOT NULL DEFAULT 'IN_PROGRESS',
    "outcome" "VoiceCallOutcome",
    "callerPhone" TEXT,
    "callerName" TEXT,
    "patientId" TEXT,
    "startedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "endedAt" TIMESTAMP(3),
    "durationSec" INTEGER NOT NULL DEFAULT 0,
    "transcript" JSONB NOT NULL DEFAULT '[]',
    "summary" TEXT,
    "recordingUrl" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "VoiceCall_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "VoiceCallEvent" (
    "id" TEXT NOT NULL,
    "callId" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "toolName" TEXT,
    "argsJson" JSONB,
    "resultJson" JSONB,
    "errorMessage" TEXT,
    "ts" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "VoiceCallEvent_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "VoiceAgentConfig_clinicId_key" ON "VoiceAgentConfig"("clinicId");

-- CreateIndex
CREATE INDEX "VoiceCall_clinicId_idx" ON "VoiceCall"("clinicId");

-- CreateIndex
CREATE INDEX "VoiceCall_status_idx" ON "VoiceCall"("status");

-- CreateIndex
CREATE INDEX "VoiceCall_startedAt_idx" ON "VoiceCall"("startedAt");

-- CreateIndex
CREATE INDEX "VoiceCall_patientId_idx" ON "VoiceCall"("patientId");

-- CreateIndex
CREATE INDEX "VoiceCallEvent_callId_idx" ON "VoiceCallEvent"("callId");

-- CreateIndex
CREATE INDEX "VoiceCallEvent_type_idx" ON "VoiceCallEvent"("type");

-- AddForeignKey
ALTER TABLE "VoiceAgentConfig" ADD CONSTRAINT "VoiceAgentConfig_clinicId_fkey" FOREIGN KEY ("clinicId") REFERENCES "Clinic"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VoiceCall" ADD CONSTRAINT "VoiceCall_clinicId_fkey" FOREIGN KEY ("clinicId") REFERENCES "Clinic"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VoiceCallEvent" ADD CONSTRAINT "VoiceCallEvent_callId_fkey" FOREIGN KEY ("callId") REFERENCES "VoiceCall"("id") ON DELETE CASCADE ON UPDATE CASCADE;

